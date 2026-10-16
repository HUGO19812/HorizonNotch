import AppKit

/// Snapshot of the system-wide "Now Playing" session.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// Position at `timestamp`; advance it with `elapsed(at:)`.
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    /// MediaRemote shuffle mode: 1 = off, 2 = albums, 3 = songs.
    var shuffleMode: Int
    var bundleID: String?
    var appName: String?
    var artworkID: Int
    /// MediaRemote repeat mode: 1 = off, 2 = one, 3 = all.
    var repeatMode: Int = 1

    var isShuffling: Bool { shuffleMode > 1 }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        let speed = rate > 0 ? rate : 1
        let value = elapsed + date.timeIntervalSince(timestamp) * speed
        return duration > 0 ? min(max(0, value), duration) : max(0, value)
    }
}

enum MediaCommand {
    case play, pause, togglePlayPause, next, previous

    /// MRMediaRemoteCommand raw values.
    var remoteCode: Int {
        switch self {
        case .play: return 0
        case .pause: return 1
        case .togglePlayPause: return 2
        case .next: return 4
        case .previous: return 5
        }
    }
}

/// Resolves the process that owns the media session to a user-facing app.
/// Browsers and WebKit play media from helper processes, so map those back
/// to their parent application.
enum MediaAppResolver {
    static func app(for pid: Int32) -> NSRunningApplication? {
        guard pid > 0 else { return nil }
        let running = NSWorkspace.shared.runningApplications
        if let app = NSRunningApplication(processIdentifier: pid) {
            guard let bundle = app.bundleIdentifier else { return app }
            if app.activationPolicy == .regular { return app }
            if bundle.hasPrefix("com.apple.WebKit") {
                return running.first { $0.bundleIdentifier == "com.apple.Safari" } ?? app
            }
            // e.g. com.google.Chrome.helper -> com.google.Chrome
            let parts = bundle.split(separator: ".")
            for length in stride(from: parts.count - 1, through: 2, by: -1) {
                let prefix = parts.prefix(length).joined(separator: ".")
                if let parent = running.first(where: { $0.bundleIdentifier == prefix && $0.activationPolicy == .regular }) {
                    return parent
                }
            }
            return app
        }
        return nil
    }
}
