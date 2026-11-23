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
    /// The heart: whether the current song is a favourite. Music answers via
    /// AppleScript, Spotify via its own like button (see SpotifyLikes);
    /// other players offer no way to read or set it.
    @Published private(set) var liked = false
    private var likedTitle = ""
    var canLike: Bool { info?.bundleID == "com.apple.Music" || info?.bundleID == SpotifyLikes.bundleID }
    private let likeQueue = DispatchQueue(label: "horizon.like", qos: .userInitiated)

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
        if usingFallback {
            fallback.seek(to: seconds)
        } else if let name = scriptablePlayerName {
            // Music and Spotify follow their own AppleScript seek reliably,
            // also while the screen is locked and for Spotify Connect.
            let position = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            likeQueue.async { Self.runScript("tell application \"\(name)\" to set player position to \(position)") }
            // With Spotify Connect the song plays on another device and the
            // reported position lags: read the real one back after the seek.
            let title = info?.title ?? ""
            for delay in [1.0, 3.5] {
                likeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    let read = Self.runScript("tell application \"\(name)\" to get player position")
                    guard let read, let value = Double(read.replacingOccurrences(of: ",", with: ".")) else { return }
                    DispatchQueue.main.async { self?.adoptPosition(value, title: title) }
                }
            }
        } else {
            bridge.send("seek \(seconds)")
        }
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

    // MARK: - Player volume

    /// The player's own volume (Spotify and Music only), independent of the
    /// system volume. Name for the row, nil for other players.
    var playerVolumeName: String? { scriptablePlayerName.map { $0 == "Music" ? "Apple Music" : $0 } }

    /// 0…1, nil when it can't be read. Blocks briefly (AppleScript).
    func readPlayerVolume() -> Double? {
        guard let name = scriptablePlayerName,
              let text = Self.runScript("tell application \"\(name)\" to get sound volume"),
              let value = Double(text) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// Coalesces drags: only the latest value is sent.
    private var pendingVolume: Double?

    func setPlayerVolume(_ value: Double) {
        guard let name = scriptablePlayerName else { return }
        let first = pendingVolume == nil
        pendingVolume = value
        guard first else { return }
        likeQueue.async { [weak self] in
            var last: Double?
            while true {
                var next: Double?
                DispatchQueue.main.sync {
                    next = self?.pendingVolume
                    if next == last { self?.pendingVolume = nil; next = nil }
                }
                guard let value = next else { return }
                last = value
                Self.runScript("tell application \"\(name)\" to set sound volume to \(Int((value * 100).rounded()))")
            }
        }
    }

    /// Takes a position read from the player itself (after a seek).
    private func adoptPosition(_ seconds: Double, title: String) {
        guard var current = info, current.title == title, seconds.isFinite, seconds >= 0 else { return }
        current.elapsed = current.duration > 0 ? min(seconds, current.duration) : seconds
        current.timestamp = Date()
        pendingSeek = (current.elapsed, current.timestamp, title)
        info = current
    }

    private var scriptablePlayerName: String? {
        switch info?.bundleID {
        case "com.apple.Music": return "Music"
        case SpotifyLikes.bundleID: return "Spotify"
        default: return nil
        }
    }

    func toggleLike() {
        guard canLike, let bundle = info?.bundleID else { return }
        let new = !liked
        liked = new
        likeQueue.async { [weak self] in
            let confirmed: Bool?
            if bundle == SpotifyLikes.bundleID {
                confirmed = SpotifyLikes.toggle(expected: new)
            } else {
                confirmed = Self.setMusicFavourite(new)
            }
            DispatchQueue.main.async {
                if let confirmed { self?.liked = confirmed } else { self?.liked = !new }
            }
        }
    }

    /// Reads the heart for a new song in the background.
    private func refreshLiked() {
        guard let info, info.title != likedTitle else { return }
        likedTitle = info.title
        guard canLike, let bundle = info.bundleID else { liked = false; return }
        likeQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            // Spotify updates its bar a moment after the track changes.
            let result = bundle == SpotifyLikes.bundleID ? SpotifyLikes.isLiked() : Self.musicFavourite()
            DispatchQueue.main.async {
                guard self?.info?.title == info.title else { return }
                self?.liked = result ?? false
            }
        }
    }

    /// Music calls it "favorited" since macOS 14.4, "loved" before.
    private static func musicFavourite() -> Bool? {
        for property in ["favorited", "loved"] {
            if let result = runScript("tell application \"Music\" to get \(property) of current track") {
                return result == "true"
            }
        }
        return nil
    }

    private static func setMusicFavourite(_ value: Bool) -> Bool? {
        for property in ["favorited", "loved"]
        where runScript("tell application \"Music\" to set \(property) of current track to \(value)\nreturn \"ok\"") != nil {
            return value
        }
        return nil
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
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

    private func apply(info incoming: NowPlayingInfo?, artwork incomingData: Data?) {
        // A chosen source (Settings → Music) hides every other player.
        var newInfo = incoming
        var data = incomingData
        if let wanted = AppSettings.shared.mediaSource.bundleID, let candidate = incoming,
           candidate.bundleID != wanted {
            newInfo = nil
            data = nil
        }
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
        refreshLiked()
    }
}
