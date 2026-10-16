import AppKit
import ApplicationServices
import Combine

/// Whether another app fills the island's screen: a full-screen app or
/// video (own space) or a borderless full-screen window (games).
///
/// Full-screen windows on a Mac with a notch leave the strip beside the
/// notch free, so their size says little. The reliable signal is the
/// focused window's "AXFullScreen" attribute (the app already has the
/// Accessibility permission for the media keys); a window covering the
/// whole screen is the fallback for games and when that is missing.
/// Checked when the space or the active app changes – no polling.
final class FullscreenMonitor: ObservableObject {
    static let shared = FullscreenMonitor()

    @Published private(set) var isFullscreen = false

    private var observers: [NSObjectProtocol] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleChecks()
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleChecks()
        })
        check()
    }

    /// Entering or leaving full screen animates for a moment; look again
    /// once the window has its final size.
    private func scheduleChecks() {
        check()
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.check() }
        }
    }

    func check() {
        let screen = NSScreen.islandScreen(preferred: AppSettings.shared.displayID)
        let now = Self.focusedWindowIsFullscreen(on: screen) || Self.screenIsCovered(screen)
        if now != isFullscreen { isFullscreen = now }
    }

    /// The frontmost app's focused window is in macOS full screen and on
    /// the island's screen.
    private static func focusedWindowIsFullscreen(on screen: NSScreen?) -> Bool {
        guard let screen, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hanging app must not stall the main thread.
        AXUIElementSetMessagingTimeout(element, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = focused as! AXUIElement
        var fullscreen: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success,
              (fullscreen as? Bool) == true else { return false }
        // With several displays: only when it is the island's screen.
        var positionValue: CFTypeRef?
        var position = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
           let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
           AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
           let primary = NSScreen.screens.first {
            // AX uses a top-left origin on the primary screen.
            let point = CGPoint(x: position.x + 1, y: primary.frame.maxY - position.y - 1)
            return screen.frame.contains(point)
        }
        return true
    }

    private static func screenIsCovered(_ screen: NSScreen?) -> Bool {
        guard let screen, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // Window bounds use a top-left origin on the primary screen.
        let frame = screen.frame
        let target = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            // A normal window, even zoomed, leaves the menu bar free.
            return abs(bounds.minX - target.minX) < 2 && abs(bounds.minY - target.minY) < 2
                && abs(bounds.width - target.width) < 2 && abs(bounds.height - target.height) < 2
        }
    }
}
