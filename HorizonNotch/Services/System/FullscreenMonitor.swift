import AppKit
import Combine

/// Whether another app fills the island's screen completely: a full-screen
/// app or video (own space) or a borderless full-screen window (games).
///
/// Checked when the space or the active app changes – no polling. Window
/// bounds of other apps are readable without Screen Recording permission.
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
        let now = Self.screenIsCovered(NSScreen.islandScreen(preferred: AppSettings.shared.displayID))
        if now != isFullscreen { isFullscreen = now }
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
