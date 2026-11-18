import AppKit
import QuartzCore

/// The lock screen's own wallpaper, live, inside our window (test mode
/// "System glass"). Our lock screen window lives in a SkyLight space above
/// the lock screen, where the system's Liquid Glass cannot see what macOS
/// draws below. LoginUIKit – the framework of the lock screen itself – hands
/// out a layer the wallpaper service renders into (pictures, Aerials,
/// dynamic wallpapers); with it behind the card, the system glass has the
/// real picture to bend. Private API: every step is checked and the host
/// simply stays empty if something is missing.
final class LockWallpaperHost {
    /// Full-screen layer to put behind the lock screen content.
    let layer = CALayer()
    private var controller: NSObject?
    private var assertion: AnyObject?
    private var size: CGSize = .zero
    private var sizing: Timer?

    private static let framework: Bool = {
        dlopen("/System/Library/PrivateFrameworks/LoginUIKit.framework/Versions/A/LoginUIKit", RTLD_LAZY) != nil
    }()

    init?(displayID: CGDirectDisplayID, size: CGSize) {
        guard Self.framework, let type = NSClassFromString("LUI2WallpaperController") as? NSObject.Type else {
            NSLog("[HorizonNotch] LoginUIKit wallpaper controller unavailable")
            return nil
        }
        // Tell the wallpaper service the lock screen presentation is wanted.
        let assertSelector = NSSelectorFromString("takeLockedAssertionWithCompletion:")
        if let method = class_getClassMethod(type, assertSelector) {
            typealias Completion = @convention(block) (AnyObject?) -> Void
            typealias Assert = @convention(c) (AnyClass, Selector, Completion) -> Void
            let assert = unsafeBitCast(method_getImplementation(method), to: Assert.self)
            // LoginUIKit keeps the block, so it must be a real heap block.
            let completion: Completion = { [weak self] token in
                DispatchQueue.main.async { self?.assertion = token }
            }
            assert(type, assertSelector, completion)
        }
        // alloc + initWithDisplayID:style:
        let initSelector = NSSelectorFromString("initWithDisplayID:style:")
        guard let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: initSelector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, Int) -> NSObject?
        let initialize = unsafeBitCast(allocated.method(for: initSelector), to: Init.self)
        let style = UserDefaults.standard.integer(forKey: "lockSystemGlassStyle")
        guard let controller = initialize(allocated, initSelector, displayID, style),
              let wallpaper = controller.value(forKey: "layer") as? CALayer else { return nil }
        self.controller = controller

        layer.addSublayer(wallpaper)
        resize(to: size)
        // The wallpaper service attaches its live layer a moment later; give
        // it the full size as soon as it is there.
        var ticks = 0
        sizing = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.resize(to: self.size)
            ticks += 1
            if ticks >= 20 { timer.invalidate() }
        }
        NSLog("[HorizonNotch] lock wallpaper host: %@ (style %ld)", wallpaper.sublayers?.description ?? "-", style)
    }

    /// Keeps the hosted wallpaper filling the window.
    func resize(to size: CGSize) {
        self.size = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(origin: .zero, size: size)
        layer.sublayers?.forEach { wallpaper in
            wallpaper.frame = layer.bounds
            wallpaper.sublayers?.forEach { $0.frame = wallpaper.bounds }
        }
        CATransaction.commit()
    }

    deinit {
        sizing?.invalidate()
        layer.removeFromSuperlayer()
    }
}
