import AppKit
import QuartzCore
import SwiftUI

/// The lock screen's live wallpaper (moving and dynamic ones too), from
/// LoginUIKit – the framework of the lock screen itself – which hands out a
/// layer the wallpaper service renders into. It only starts drawing a
/// moment after the screen locked, so it lies on top of the still picture
/// (Wallpaper): until it draws it is transparent and the still shows,
/// afterwards it moves. Private API: every step is checked and the host
/// simply stays empty if something is missing.
final class LockWallpaperHost {
    /// The one shown while the screen is locked (set by LockScreenController).
    static var current: LockWallpaperHost?

    /// Screen-sized layer; LiveWallpaperPiece shows the part behind a view.
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
            return nil
        }
        // Ask the wallpaper service for the lock screen presentation.
        let assertSelector = NSSelectorFromString("takeLockedAssertionWithCompletion:")
        if let method = class_getClassMethod(type, assertSelector) {
            typealias Completion = @convention(block) (AnyObject?) -> Void
            typealias Assert = @convention(c) (AnyClass, Selector, Completion) -> Void
            let assert = unsafeBitCast(method_getImplementation(method), to: Assert.self)
            // LoginUIKit keeps the block, so it must be a real heap block.
            let completion: Completion = { [weak self] token in
                DispatchQueue.main.async {
                    guard let self else { return Self.release(token) }
                    self.assertion = token
                }
            }
            assert(type, assertSelector, completion)
        }
        // alloc + initWithDisplayID:style: (0 = the lock screen presentation)
        let initSelector = NSSelectorFromString("initWithDisplayID:style:")
        guard let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: initSelector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, Int) -> NSObject?
        let initialize = unsafeBitCast(allocated.method(for: initSelector), to: Init.self)
        guard let controller = initialize(allocated, initSelector, displayID, 0),
              let wallpaper = controller.value(forKey: "layer") as? CALayer else { return nil }
        self.controller = controller
        layer.addSublayer(wallpaper)
        resize(to: size)
        // The service attaches its live layer a little later; keep it sized.
        var ticks = 0
        sizing = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.resize(to: self.size)
            ticks += 1
            if ticks >= 40 { timer.invalidate() }
        }
    }

    /// Keeps the hosted wallpaper at screen size (the position is set by
    /// whoever shows it).
    func resize(to size: CGSize) {
        self.size = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: size)
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
        sizing?.invalidate()
        Self.release(assertion)
        layer.removeFromSuperlayer()
    }
}

/// The part of the live lock screen wallpaper right behind this view.
struct LiveWallpaperPiece: NSViewRepresentable {
    func makeNSView(context: Context) -> PieceView { PieceView() }
    func updateNSView(_ view: PieceView, context: Context) { view.needsLayout = true }

    final class PieceView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let host = LockWallpaperHost.current, window != nil, let layer else { return }
            if host.layer.superlayer !== layer { layer.addSublayer(host.layer) }
            // The lock screen window covers the screen: window coordinates
            // are screen coordinates.
            let inWindow = convert(bounds, to: nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.layer.frame = CGRect(x: -inWindow.minX, y: -inWindow.minY,
                                      width: host.layer.bounds.width, height: host.layer.bounds.height)
            CATransaction.commit()
        }
    }
}
