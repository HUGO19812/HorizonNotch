import AppKit

/// Talks to the MediaRemote helper (HNMediaBridge.dylib loaded into
/// /usr/bin/perl, see MediaBridge/). The helper pushes a JSON line whenever
/// the now-playing state changes, so nothing here polls.
final class MediaBridgeClient {
    struct State {
        var info: NowPlayingInfo?
        /// Only set when the artwork changed.
        var artwork: Data?
    }

    var onState: ((State) -> Void)?
    /// Called when the helper keeps crashing; the caller falls back.
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopped = false
    private var crashTimes: [Date] = []
    private let ioQueue = DispatchQueue(label: "horizon.mediabridge.io")

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func send(_ line: String) {
        guard let input else { return }
        ioQueue.async {
            try? input.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    // MARK: - Process

    private func launch() {
        guard let script = Bundle.main.path(forResource: "hn-media", ofType: "pl"),
              let library = Bundle.main.path(forResource: "HNMediaBridge", ofType: "dylib") else {
            NSLog("[HorizonNotch] media bridge files missing from bundle")
            onUnavailable?()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, library]
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.processEnded() }
        }

        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
        } catch {
            NSLog("[HorizonNotch] media bridge failed to start: \(error)")
            processEnded()
        }
    }

    private func processEnded() {
        process = nil
        input = nil
        guard !stopped else { return }
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashTimes.count >= 3 {
            NSLog("[HorizonNotch] media bridge keeps exiting, using fallback")
            onUnavailable?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.stopped, self.process == nil else { return }
            self.launch()
        }
    }

    // MARK: - Parsing

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ json: [String: Any]) {
        guard json["type"] as? String == "state" else {
            if json["type"] as? String == "error" {
                NSLog("[HorizonNotch] media bridge: \(json["message"] ?? "")")
            }
            return
        }
        var state = State()
        if json["empty"] as? Bool != true {
            let pid = (json["pid"] as? NSNumber)?.int32Value ?? 0
            let rate = (json["rate"] as? NSNumber)?.doubleValue ?? 0
            let stamp = (json["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
            let info = NowPlayingInfo(
                title: json["title"] as? String ?? "",
                artist: json["artist"] as? String ?? "",
                album: json["album"] as? String ?? "",
                duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0,
                elapsed: (json["elapsed"] as? NSNumber)?.doubleValue ?? 0,
                timestamp: stamp,
                rate: rate,
                isPlaying: (json["playing"] as? Bool ?? false) || rate > 0,
                shuffleMode: (json["shuffle"] as? NSNumber)?.intValue ?? 1,
                bundleID: nil,
                appName: nil,
                artworkID: (json["artworkId"] as? NSNumber)?.intValue ?? 0)
            state.info = info
            if let base64 = json["artwork"] as? String { state.artwork = Data(base64Encoded: base64) }
            DispatchQueue.main.async { [weak self] in
                var resolved = state
                if let app = MediaAppResolver.app(for: pid) {
                    resolved.info?.bundleID = app.bundleIdentifier
                    resolved.info?.appName = app.localizedName
                }
                if resolved.info?.title.isEmpty == true { resolved.info = nil }
                self?.onState?(resolved)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }
}
