import AppKit

/// Fallback for when the MediaRemote helper is unavailable: asks Music and
/// Spotify directly via AppleScript. Only polls while one of them runs, and
/// never launches them.
final class AppleScriptMediaSource {
    var onState: ((NowPlayingInfo?, Data?) -> Void)?

    private struct Player {
        let bundleID: String
        let name: String
    }

    private let players = [
        Player(bundleID: "com.spotify.client", name: "Spotify"),
        Player(bundleID: "com.apple.Music", name: "Music"),
    ]
    private let queue = DispatchQueue(label: "horizon.applescript")
    private var timer: Timer?
    private var lastArtworkURL: String?
    private var activePlayer: Player?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.5
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func send(_ command: MediaCommand) {
        guard let player = activePlayer else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        run("tell application \"\(player.name)\" to \(verb)")
        poll()
    }

    func seek(to seconds: Double) {
        guard let player = activePlayer else { return }
        run("tell application \"\(player.name)\" to set player position to \(seconds)")
    }

    private func poll() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = players.filter { running.contains($0.bundleID) }
        guard !candidates.isEmpty else {
            activePlayer = nil
            onState?(nil, nil)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            var best: (Player, NowPlayingInfo, String?)?
            for player in candidates {
                guard let (info, artworkURL) = self.query(player) else { continue }
                if best == nil || (info.isPlaying && !(best!.1.isPlaying)) { best = (player, info, artworkURL) }
            }
            var artwork: Data?
            if let url = best?.2, url != self.lastArtworkURL, let remote = URL(string: url) {
                artwork = try? Data(contentsOf: remote)
                self.lastArtworkURL = url
            }
            DispatchQueue.main.async {
                self.activePlayer = best?.0
                self.onState?(best?.1, artwork)
            }
        }
    }

    private func query(_ player: Player) -> (NowPlayingInfo, String?)? {
        let artwork = player.name == "Spotify" ? "artwork url of t" : "\"\""
        let durationScale = player.name == "Spotify" ? "/ 1000" : ""
        let source = """
        tell application "\(player.name)"
            if player state is stopped then return ""
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) \(durationScale) as string) & linefeed & (player position as string) & linefeed & \(artwork)
        end tell
        """
        guard let output = run(source), !output.isEmpty else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 6 else { return nil }
        let number: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let playing = lines[0] == "playing"
        let info = NowPlayingInfo(title: lines[1], artist: lines[2], album: lines[3],
                                  duration: number(lines[4]), elapsed: number(lines[5]),
                                  timestamp: Date(), rate: playing ? 1 : 0, isPlaying: playing,
                                  shuffleMode: 1, bundleID: player.bundleID, appName: player.name,
                                  artworkID: lines.count > 6 ? lines[6].hashValue : 0)
        return (info, lines.count > 6 && !lines[6].isEmpty ? lines[6] : nil)
    }

    @discardableResult
    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
