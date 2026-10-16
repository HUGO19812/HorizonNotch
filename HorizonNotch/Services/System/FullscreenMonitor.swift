import AppKit
import ApplicationServices
import Combine

/// Whether another app fills the island's screen: a full-screen app or
/// video (own space) or a borderless full-screen window (games).
///
/// Main signal, as in Boring Notch (MacroVisionKit): the window server's
/// list of spaces per display. The display's current space is a
/// full-screen space when it has a "TileLayoutManager". That needs no
/// permission and does not depend on window sizes (full-screen windows
/// leave the strip beside the notch free). If the private function is
/// missing, the focused window's AXFullScreen attribute and a window
/// covering the whole screen are used instead.
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
        let fullscreenSpace = Self.currentSpaceIsFullscreen(on: screen) ?? Self.focusedWindowIsFullscreen(on: screen)
        // Borderless full-screen games do not get their own space.
        let now = fullscreenSpace || Self.screenIsCovered(screen)
        if now != isFullscreen { isFullscreen = now }
    }

    // MARK: - Spaces (window server)

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: ConnectionFn? = symbol("SLSMainConnectionID") ?? symbol("CGSMainConnectionID")
    private static let copySpaces: CopySpacesFn? = symbol("SLSCopyManagedDisplaySpaces") ?? symbol("CGSCopyManagedDisplaySpaces")

    private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// nil when the window server cannot be asked.
    private static func currentSpaceIsFullscreen(on screen: NSScreen?) -> Bool? {
        guard let screen, let connection, let copySpaces,
              let displays = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let uuid = screen.displayUUID
        for display in displays {
            // "Main" when all displays share one set of spaces.
            let identifier = display["Display Identifier"] as? String
            guard identifier == "Main" || identifier == uuid || displays.count == 1,
                  let current = display["Current Space"] as? [String: Any],
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let currentID = current["ManagedSpaceID"] as? Int ?? current["id64"] as? Int ?? -1
            let active = spaces.first { ($0["ManagedSpaceID"] as? Int) == currentID } ?? current
            return active["TileLayoutManager"] != nil
        }
        return false
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

extension NSScreen {
    /// The display's UUID as the window server names it in its space list.
    var displayUUID: String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }
}
