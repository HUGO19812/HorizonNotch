import AppKit
import Combine

/// Announces files that finish downloading into ~/Downloads. Watches the
/// folder with a kqueue source (no polling). Browsers write to a temporary
/// name (.download, .crdownload, .part) and rename at the end, so a new
/// visible, non-temporary name means "done". Opt-in, because macOS asks for
/// access to the Downloads folder.
final class DownloadWatcher {
    private let post: (IslandEvent) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var pending: DispatchWorkItem?
    private var subscription: AnyCancellable?
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private static let temporary = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    init(post: @escaping (IslandEvent) -> Void) {
        self.post = post
        subscription = AppSettings.shared.$notifyDownloads
            .sink { [weak self] on in DispatchQueue.main.async { on ? self?.start() : self?.stop() } }
    }

    private func start() {
        guard source == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("[HorizonNotch] no access to Downloads")
            return
        }
        known = Set(listing())
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    // Folder writes come in bursts while a download runs; look once it settles.
    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func scan() {
        let now = Set(listing())
        let added = now.subtracting(known)
        known = now
        for name in added.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            guard !Self.temporary.contains(url.pathExtension.lowercased()) else { continue }
            post(IslandEvent(symbol: "arrow.down.circle.fill", tint: .blue, title: name,
                             detail: L("Geladen", "Downloaded"),
                             image: NSWorkspace.shared.icon(forFile: url.path),
                             duration: 5,
                             action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
        }
    }
}
