import AppKit

/// Measures the hardware notch of a screen, or describes the virtual
/// island used on displays without one.
struct NotchGeometry: Equatable {
    /// Size of the hardware notch (or of the virtual capsule).
    let notchSize: CGSize
    let hasNotch: Bool
    /// Gap between the screen's top edge and the virtual capsule.
    let topInset: CGFloat

    static let virtualSize = CGSize(width: 180, height: 32)

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            // safeAreaInsets.top is the menu bar height; on some models it
            // is a little taller than the camera housing (Appearance).
            let height = screen.safeAreaInsets.top + CGFloat(AppSettings.shared.notchHeightAdjust)
            notchSize = CGSize(width: width, height: max(20, height))
            hasNotch = true
            topInset = 0
        } else {
            notchSize = Self.virtualSize
            hasNotch = false
            topInset = 6
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil }

    /// The screen the island should live on: the user's choice if it is
    /// connected, otherwise the first screen with a notch, else the main one.
    static func islandScreen(preferred id: CGDirectDisplayID) -> NSScreen? {
        if id != 0, let chosen = screens.first(where: { $0.displayID == id }) { return chosen }
        return screens.first(where: \.hasNotch) ?? main ?? screens.first
    }
}
