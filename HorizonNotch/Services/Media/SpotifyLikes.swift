import AppKit
import ApplicationServices

/// Reads and toggles Spotify's "Liked Songs" heart without a Web API key.
///
/// Spotify offers no AppleScript or MediaRemote command for it, so this uses
/// the like button in Spotify's own now-playing bar through Accessibility
/// (Horizon Notch already asks for that permission). Spotify is a Chromium
/// app: its web content only appears in the accessibility tree after
/// `AXManualAccessibility` is set on the app.
enum SpotifyLikes {
    static let bundleID = "com.spotify.client"

    /// nil when the state can't be read (no window, no permission).
    static func isLiked() -> Bool? {
        guard let button = likeButton() else { return nil }
        return state(of: button)
    }

    /// Presses the button; returns the new state when it could be read.
    @discardableResult
    static func toggle() -> Bool? {
        guard let button = likeButton() else { return nil }
        let before = state(of: button)
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return nil }
        return !before
    }

    // MARK: - Accessibility

    /// "Add to Liked Songs" while not liked; afterwards Spotify relabels the
    /// button ("Add to playlist") and marks it checked.
    private static let notLikedWords = ["liked songs", "lieblingssongs", "titres likés", "canciones que te gustan",
                                        "brani che ti piacciono", "gelikete nummers"]
    private static let likedWords = ["playlist", "remove from", "entfernen"]

    private static func state(of button: AXUIElement) -> Bool {
        if role(of: button) == kAXCheckBoxRole as String,
           let checked = attribute(button, kAXValueAttribute) as? NSNumber {
            return checked.boolValue
        }
        let label = text(of: button)
        let removes = label.contains("remove") || label.contains("entfernen")
        return removes || !notLikedWords.contains(where: label.contains)
    }

    private static func likeButton() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            guard let frame = frame(of: window), frame.height > 200 else { continue }
            // The now-playing bar is the bottom strip of the main window; the
            // like button sits in its left half, right of the cover.
            let bar = CGRect(x: frame.minX + 40, y: frame.maxY - 130, width: frame.width / 2 - 40, height: 130)
            var visited = 0
            if let found = search(window, bar: bar, visited: &visited) { return found }
        }
        return nil
    }

    private static func search(_ element: AXUIElement, bar: CGRect, visited: inout Int) -> AXUIElement? {
        guard visited < 4000 else { return nil }
        visited += 1
        let box = frame(of: element)
        // Skip whole subtrees that lie above the bar.
        if let box, box.height > 0, box.maxY < bar.minY { return nil }
        let role = role(of: element)
        if role == kAXButtonRole as String || role == kAXCheckBoxRole as String,
           let box, bar.contains(CGPoint(x: box.midX, y: box.midY)) {
            let label = text(of: element)
            if notLikedWords.contains(where: label.contains) || likedWords.contains(where: label.contains) {
                return element
            }
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let found = search(child, bar: bar, visited: &visited) { return found }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func role(of element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute) as? String ?? ""
    }

    private static func text(of element: AXUIElement) -> String {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .compactMap { attribute(element, $0) as? String }
            .joined(separator: " ")
            .lowercased()
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
