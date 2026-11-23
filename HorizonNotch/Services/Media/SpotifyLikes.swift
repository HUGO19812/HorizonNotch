import AppKit

/// Spotify's "Save to Liked Songs" without a Web API key.
///
/// Spotify offers no AppleScript or MediaRemote command for it and hides its
/// player from Accessibility (only the window buttons are visible), so the
/// state can't be read. What works is Spotify's own shortcut, ⌥⇧B, sent to
/// the app in the background: it toggles the current song.
enum SpotifyLikes {
    static let bundleID = "com.spotify.client"

    /// Sends ⌥⇧B to Spotify. Needs the Accessibility permission.
    @discardableResult
    static func toggle() -> Bool {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: false) else { return false }
        down.flags = [.maskAlternate, .maskShift]
        up.flags = [.maskAlternate, .maskShift]
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return true
    }
}
