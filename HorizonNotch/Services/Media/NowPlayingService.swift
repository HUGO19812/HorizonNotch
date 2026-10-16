import AppKit
import Combine
import SwiftUI

/// Single source of truth for media: MediaRemote via the helper, with the
/// AppleScript source as fallback.
final class NowPlayingService: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    /// Vivid colour taken from the cover, used for the visualizer.
    @Published private(set) var accent: Color = .white
    @Published private(set) var usingFallback = false

    /// A seek from the island the player has not confirmed yet. Right after
    /// seeking, players still report the old position once or twice; those
    /// updates are corrected so the progress bar does not jump back.
    private var pendingSeek: (target: Double, at: Date, title: String)?

    private let bridge = MediaBridgeClient()
    private let fallback = AppleScriptMediaSource()

    func start() {
        bridge.onState = { [weak self] state in
            self?.apply(info: state.info, artwork: state.artwork)
        }
        bridge.onUnavailable = { [weak self] in self?.switchToFallback() }
        fallback.onState = { [weak self] info, artwork in
            self?.apply(info: info, artwork: artwork)
        }
        bridge.start()
    }

    func stop() {
        bridge.stop()
        fallback.stop()
    }

    // MARK: - Controls

    func send(_ command: MediaCommand) {
        if usingFallback {
            fallback.send(command)
            return
        }
        bridge.send("cmd \(command.remoteCode)")
        // Reflect play/pause immediately; the helper confirms shortly after.
        if var current = info, command == .togglePlayPause {
            current.elapsed = current.elapsed(at: Date())
            current.timestamp = Date()
            current.isPlaying.toggle()
            info = current
        }
    }

    /// Seeks made from the island (scrubber, lyrics, gestures), in seconds
    /// moved. Players report positions with some jitter, so seeks are not
    /// guessed from position updates.
    let userSeeked = PassthroughSubject<Double, Never>()

    func seek(to seconds: Double) {
        if var current = info {
            userSeeked.send(seconds - current.elapsed(at: Date()))
            current.elapsed = seconds
            current.timestamp = Date()
            info = current
            pendingSeek = (seconds, current.timestamp, current.title)
        }
        if usingFallback { fallback.seek(to: seconds) } else { bridge.send("seek \(seconds)") }
    }

    /// Off → all → one → off, like Music.
    func cycleRepeat() {
        guard let current = info, !usingFallback else { return }
        let next = current.repeatMode == 3 ? 2 : (current.repeatMode == 2 ? 1 : 3)
        bridge.send("repeat \(next)")
    }

    func toggleShuffle() {
        guard let current = info, !usingFallback else { return }
        bridge.send("shuffle \(current.isShuffling ? 1 : 3)")
    }

    func openPlayerApp() {
        guard let bundle = info?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - State

    private func switchToFallback() {
        guard !usingFallback else { return }
        usingFallback = true
        fallback.start()
    }

    private func apply(info newInfo: NowPlayingInfo?, artwork data: Data?) {
        if newInfo == nil {
            if info != nil { info = nil }
            if artwork != nil { artwork = nil }
            CoverAccent.shared.color = nil
            return
        }
        if let data, let image = NSImage(data: data) {
            artwork = image
            accent = Color(nsColor: ColorExtractor.vibrantColor(of: image))
            CoverAccent.shared.color = accent
        } else if newInfo?.artworkID == 0, artwork != nil {
            artwork = nil
            accent = .white
            CoverAccent.shared.color = nil
        }
        var updated = newInfo
        if let seek = pendingSeek, var incoming = newInfo {
            let now = Date()
            if incoming.title != seek.title || now.timeIntervalSince(seek.at) > 3 {
                pendingSeek = nil
            } else {
                let expected = seek.target + (incoming.isPlaying ? now.timeIntervalSince(seek.at) : 0)
                if abs(incoming.elapsed(at: now) - expected) > 1.5 {
                    // Stale position from before the seek: keep ours.
                    incoming.elapsed = incoming.duration > 0 ? min(expected, incoming.duration) : expected
                    incoming.timestamp = now
                    updated = incoming
                } else {
                    pendingSeek = nil
                }
            }
        }
        if updated != info { info = updated }
    }
}
