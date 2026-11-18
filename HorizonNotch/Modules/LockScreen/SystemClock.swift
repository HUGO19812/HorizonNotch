import AppKit
import SwiftUI

/// The lock screen clock exactly as macOS draws it: LoginUIKit's own date
/// and time views (your clock font, size and glass look), shown when the
/// large cover hides the system's clock. Private API: every step is
/// checked, and without it the hand-made clock is used.
enum SystemClock {
    private static let loaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/LoginUIKit.framework/Versions/A/LoginUIKit", RTLD_LAZY) != nil
            && NSClassFromString("LUI2BigTimeViewController") != nil
            && NSClassFromString("LUI2DateViewController") != nil
    }()

    static var isAvailable: Bool { loaded && settings != nil }

    /// The user's clock settings (font, weight, 24-hour time).
    static let settings: NSObject? = {
        guard loaded, let uid = Wallpaper.generatedUID,
              let type = NSClassFromString("LUIClockSettings") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithUserGUID:")
        guard let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: selector) else { return nil }
        return allocated.perform(selector, with: uid)?.takeUnretainedValue() as? NSObject
    }()

    /// The clock font macOS uses, at its own size (for the tinted clock).
    static let timeFont: NSFont? = {
        guard let controller = makeController("LUI2BigTimeViewController") else { return nil }
        _ = controller.view
        return controller.perform(NSSelectorFromString("_timeFont"))?.takeUnretainedValue() as? NSFont
    }()

    static func makeController(_ name: String) -> NSViewController? {
        guard loaded, let type = NSClassFromString(name) as? NSViewController.Type else { return nil }
        let controller = type.init()
        if let settings { controller.setValue(settings, forKey: "clockSettings") }
        return controller
    }
}

/// One of the two system views, centred in its frame.
struct SystemClockView: NSViewRepresentable {
    enum Part { case time, date }
    let part: Part
    /// Changes every minute so the time is redrawn.
    let minute: Date

    func makeCoordinator() -> NSViewController? {
        SystemClock.makeController(part == .time ? "LUI2BigTimeViewController" : "LUI2DateViewController")
    }

    func makeNSView(context: Context) -> CenteringView {
        let view = CenteringView()
        if let controller = context.coordinator { view.addSubview(controller.view) }
        return view
    }

    func updateNSView(_ view: CenteringView, context: Context) {
        guard let controller = context.coordinator else { return }
        let selector = NSSelectorFromString(part == .time ? "_updateTime" : "_timerFired")
        if controller.responds(to: selector) { controller.perform(selector) }
        view.needsLayout = true
    }

    final class CenteringView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            guard let content = subviews.first else { return }
            let size = content.fittingSize
            content.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height)
        }
    }
}
