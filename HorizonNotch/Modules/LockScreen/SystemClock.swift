import AppKit
import ObjectiveC
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

    /// The chosen clock font (e.g. ".ADTSlabSoftNumeric-Regular") and its
    /// weight on the font's own axis.
    static var fontName: String? { settings?.value(forKey: "bigClockFontName") as? String }
    static var fontWeight: CGFloat { (settings?.value(forKey: "bigClockFontWeight") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }

    /// The system's own size for the big clock.
    private static let defaultTimeSize: CGFloat = 156.38

    /// The clock font macOS uses, at its own size (for the tinted clock).
    static let timeFont: NSFont? = {
        if let name = fontName, let face = ClockFont.systemFont(named: name, size: defaultTimeSize) {
            return weighted(face) as NSFont
        }
        guard let controller = makeController("LUI2BigTimeViewController") else { return nil }
        _ = controller.view
        return controller.perform(NSSelectorFromString("_timeFont"))?.takeUnretainedValue() as? NSFont
    }()

    private static func weighted(_ font: CTFont) -> CTFont {
        guard fontWeight > 0 else { return font }
        let wght = 0x7767_6874 // 'wght'
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [wght: fontWeight]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    static func makeController(_ name: String) -> NSViewController? {
        guard loaded, let type = NSClassFromString(name) as? NSViewController.Type else { return nil }
        let controller = type.init()
        if let settings { controller.setValue(settings, forKey: "clockSettings") }
        return controller
    }

    /// LoginUIKit asks CoreText for the clock font by its system name, which
    /// only Apple's processes get (others fall back to SF Soft). Hand its
    /// glass view a copy registered under a plain name instead.
    static func applyFont(to controller: NSViewController) {
        guard let name = fontName, let usable = ClockFont.usableName(for: name),
              controller.responds(to: NSSelectorFromString("glassTextView")),
              let glass = controller.value(forKey: "glassTextView") as AnyObject? else { return }
        let setSelector = NSSelectorFromString("setDisplayFont:size:weight:")
        let sizeSelector = NSSelectorFromString("_fontSize")
        guard glass.responds(to: setSelector), let setIMP = class_getMethodImplementation(object_getClass(glass), setSelector)
        else { return }
        var size = defaultTimeSize
        if controller.responds(to: sizeSelector),
           let sizeIMP = class_getMethodImplementation(object_getClass(controller), sizeSelector) {
            typealias SizeFn = @convention(c) (AnyObject, Selector) -> CGFloat
            size = unsafeBitCast(sizeIMP, to: SizeFn.self)(controller, sizeSelector)
        }
        typealias SetFn = @convention(c) (AnyObject, Selector, NSString, CGFloat, CGFloat) -> Void
        unsafeBitCast(setIMP, to: SetFn.self)(glass, setSelector, usable as NSString, size, fontWeight)
    }
}

/// One of the two system views, centred in its frame.
struct SystemClockView: NSViewRepresentable {
    enum Part { case time, date }
    let part: Part
    /// Changes every minute so the time is redrawn.
    let minute: Date

    func makeCoordinator() -> NSViewController? {
        let controller = SystemClock.makeController(part == .time ? "LUI2BigTimeViewController" : "LUI2DateViewController")
        if part == .time, let controller {
            _ = controller.view
            SystemClock.applyFont(to: controller)
        }
        return controller
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
        // LoginUIKit may set its own (unreachable) font again on updates.
        if part == .time { SystemClock.applyFont(to: controller) }
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
