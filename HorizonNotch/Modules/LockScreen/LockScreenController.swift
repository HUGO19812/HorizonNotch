import AppKit
import Combine
import SwiftUI

/// Shows the music player on the lock screen.
///
/// Locking is detected through the distributed notifications
/// "com.apple.screenIsLocked"/"com.apple.screenIsUnlocked". The widget window
/// is moved into a SkyLight space above the lock screen (see SkyLight.swift);
/// without that private API a window cannot appear there at all.
final class LockScreenController {
    private let nowPlaying: NowPlayingService
    private let lyrics: LyricsService
    /// Large cover / lyrics; back to the small player on every lock.
    private let state = LockScreenState()
    private let settings = AppSettings.shared
    private var window: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var lyricsPrefetch: AnyCancellable?
    private(set) var isShowing = false
    var onLockChange: ((Bool) -> Void)?
    /// For the notch: a click on its cover opens the large player.
    static weak var current: LockScreenController?

    /// The same large player as on the lock screen, but as an ordinary
    /// full-screen window while the Mac is in use (see `showPlayer`).
    private let previewState = LockScreenState()
    private var previewWindow: NSPanel?
    private var previewSubscription: AnyCancellable?
    private var keyMonitor: Any?

    init(nowPlaying: NowPlayingService, lyrics: LyricsService) {
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        let center = DistributedNotificationCenter.default()
        Self.current = self
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.locked() })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.unlocked() })
        // With "cover and lyrics" as the start view, each song's lyrics are
        // fetched as it starts (one request, cached): on lock it is then
        // already known whether there are any, so the large player opens in
        // the right layout instead of moving there.
        lyricsPrefetch = nowPlaying.$info
            .compactMap { $0 }
            .removeDuplicates { $0.artist == $1.artist && $0.title == $1.title }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self, self.settings.lockScreenWidgets, self.settings.lockScreenSpicyLyrics,
                      self.settings.lockScreenStart == .lyrics else { return }
                self.lyrics.load(for: info)
            }
    }

    private func locked() {
        hidePlayer(animated: false)
        onLockChange?(true)
        guard settings.lockScreenWidgets else { return }
        show()
    }

    private func unlocked() {
        onLockChange?(false)
        hide()
        nowPlaying.sendPendingLike()
    }

    func show() {
        guard !isShowing, let screen = NSScreen.islandScreen(preferred: settings.displayID) else { return }
        state.reset()
        Wallpaper.shared.load(for: screen)
        let panel = window ?? makeWindow()
        // The view only exists while shown, so nothing updates in the
        // background (the progress bar ticks twice a second while playing).
        let host = NSHostingView(rootView: LockScreenView(nowPlaying: nowPlaying, lyrics: lyrics, state: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if !SkyLight.moveAboveLockScreen(panel) {
            NSLog("[HorizonNotch] lock screen space unavailable")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        isShowing = true
    }

    /// Opens the large player full screen over everything (Esc, the faint
    /// close button or a click on the cover closes it): the lock screen's
    /// view, not on the lock screen. Starts large even when the lock screen
    /// starts small.
    func showPlayer() {
        // Already open (perhaps behind another app's window): to the front.
        if let open = previewWindow {
            NSApp.activate(ignoringOtherApps: true)
            open.makeKeyAndOrderFront(nil)
            return
        }
        guard !isShowing, nowPlaying.info != nil,
              let screen = NSScreen.islandScreen(preferred: settings.displayID) else { return }
        previewState.reset()
        if !previewState.large { previewState.large = true }
        Wallpaper.shared.load(for: screen)
        let panel = KeyPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // Panels hide when the app loses focus (a click on the Dock, another
        // app); this one stays until it is closed.
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: LockScreenView(nowPlaying: nowPlaying, lyrics: lyrics, state: previewState,
                                                          onClose: { [weak self] in self?.hidePlayer() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        previewWindow = panel
        // Back to the small player there = close.
        previewSubscription = previewState.$large.dropFirst().filter { !$0 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.hidePlayer() } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.hidePlayer()
            return nil
        }
    }

    func hidePlayer(animated: Bool = true) {
        guard let panel = previewWindow else { return }
        previewWindow = nil
        previewSubscription = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let close = {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        guard animated else { close(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: close)
    }

    func hide() {
        guard isShowing, let panel = window else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.isShowing == false else { return }
            panel.orderOut(nil)
            panel.contentView = nil
        })
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        window = panel
        return panel
    }
}

/// A borderless panel that can take the keyboard (for Esc).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
