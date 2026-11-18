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
    private var locked = false
    private let style: Int
    private var size: CGSize = .zero
    private var sizing: Timer?

    private static let framework: Bool = {
        dlopen("/System/Library/PrivateFrameworks/LoginUIKit.framework/Versions/A/LoginUIKit", RTLD_LAZY) != nil
    }()

    /// The display this host shows the wallpaper of.
    let displayID: CGDirectDisplayID

    /// Created ahead of time (see LockScreenController.prepareSystemGlass):
    /// connecting to the wallpaper service takes a moment, and a host made
    /// only when the screen locks shows nothing for the first seconds.
    init?(displayID: CGDirectDisplayID, size: CGSize) {
        guard Self.framework, let type = NSClassFromString("LUI2WallpaperController") as? NSObject.Type else {
            NSLog("[HorizonNotch] LoginUIKit wallpaper controller unavailable")
            return nil
        }
        self.displayID = displayID
        // alloc + initWithDisplayID:style:
        let initSelector = NSSelectorFromString("initWithDisplayID:style:")
        guard let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: initSelector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, Int) -> NSObject?
        let initialize = unsafeBitCast(allocated.method(for: initSelector), to: Init.self)
        // 1 = the desktop presentation, which macOS keeps drawing all the
        // time (pictures, Aerials, dynamic) – there at once when the screen
        // locks. 0, the lock presentation, only starts after the system's
        // own lock animation, seconds too late.
        let style = UserDefaults.standard.object(forKey: "lockSystemGlassStyle") as? Int ?? 1
        self.style = style
        guard let controller = initialize(allocated, initSelector, displayID, style),
              let wallpaper = controller.value(forKey: "layer") as? CALayer else { return nil }
        self.controller = controller

        layer.addSublayer(wallpaper)
        resize(to: size)
        NSLog("[HorizonNotch] lock wallpaper host: %@ (style %ld)", wallpaper.sublayers?.description ?? "-", style)
    }

    /// The screen is locked: ask the wallpaper service for the lock screen
    /// presentation and keep the hosted layer at full size while it attaches.
    func lockBegan(size: CGSize) {
        locked = true
        resize(to: size)
        if style == 0, assertion == nil, let type = NSClassFromString("LUI2WallpaperController") {
            let assertSelector = NSSelectorFromString("takeLockedAssertionWithCompletion:")
            if let method = class_getClassMethod(type, assertSelector) {
                typealias Completion = @convention(block) (AnyObject?) -> Void
                typealias Assert = @convention(c) (AnyClass, Selector, Completion) -> Void
                let assert = unsafeBitCast(method_getImplementation(method), to: Assert.self)
                // LoginUIKit keeps the block, so it must be a real heap block.
                let completion: Completion = { [weak self] token in
                    DispatchQueue.main.async {
                        guard let self, self.locked else { return Self.release(token) }
                        self.assertion = token
                    }
                }
                assert(type, assertSelector, completion)
            }
        }
        sizing?.invalidate()
        var ticks = 0
        sizing = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.resize(to: self.size)
            ticks += 1
            if ticks >= 12 { timer.invalidate() }
        }
    }

    /// Unlocked: let go of the lock presentation, keep the connection.
    func lockEnded() {
        locked = false
        sizing?.invalidate()
        Self.release(assertion)
        assertion = nil
        layer.removeFromSuperlayer()
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

    private static func release(_ token: AnyObject?) {
        if let token = token as? NSObject, token.responds(to: NSSelectorFromString("invalidate")) {
            token.perform(NSSelectorFromString("invalidate"))
        }
    }

    deinit {
        lockEnded()
    }
}
