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
        guard let button = findButton() else { return nil }
        return state(of: button)
    }

    /// Presses the button; returns the new state when it could be read.
    /// Without a readable button it falls back to Spotify's own shortcut
    /// for "Save to Liked Songs" (⌥⇧B) and returns `expected`.
    @discardableResult
    static func toggle(expected: Bool) -> Bool? {
        if let button = findButton() {
            let before = state(of: button)
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success { return !before }
            NSLog("[HorizonNotch] Spotify like: press failed")
        }
        return pressShortcut() ? expected : nil
    }

    /// Spotify only builds its web content's accessibility tree after it
    /// was asked to; the first look right after that often finds nothing.
    private static func findButton() -> AXUIElement? {
        guard AXIsProcessTrusted() else {
            NSLog("[HorizonNotch] Spotify like: Accessibility not granted")
            return nil
        }
        for attempt in 0..<3 {
            if let button = likeButton() { return button }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.35) }
        }
        NSLog("[HorizonNotch] Spotify like: button not found")
        return nil
    }

    private static func pressShortcut() -> Bool {
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

    // MARK: - Accessibility

    /// "Add to Liked Songs" while not liked; afterwards Spotify relabels the
    /// button ("Add to playlist") and marks it checked.
    private static let notLikedWords = ["liked songs", "lieblingssongs", "titres likés", "canciones que te gustan",
                                        "brani che ti piacciono", "gelikete nummers"]
    private static let likedWords = ["playlist", "remove", "entfernen"]

    /// Spotify marks the liked heart as checked (aria-checked); that wins.
    /// Otherwise only the button's own label counts – its tooltip can say
    /// "Liked Songs" for a liked song too, which read as "not liked".
    private static func state(of button: AXUIElement) -> Bool {
        let value = attribute(button, kAXValueAttribute)
        let label = ((attribute(button, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? attribute(button, kAXTitleAttribute) as? String ?? "").lowercased()
        let liked: Bool
        if let checked = value as? NSNumber {
            liked = checked.boolValue
        } else if likedWords.contains(where: label.contains) {
            liked = true
        } else {
            liked = !notLikedWords.contains(where: label.contains)
        }
        NSLog("[HorizonNotch] Spotify like button: role=%@ label=%@ value=%@ -> %@", role(of: button), label,
              String(describing: value), liked ? "liked" : "not liked")
        return liked
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
        guard visited < 8000 else { return nil }
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
