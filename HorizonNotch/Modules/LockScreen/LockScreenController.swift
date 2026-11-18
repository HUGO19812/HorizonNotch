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
    /// Test mode "System glass": the live lock screen wallpaper behind us,
    /// kept connected between locks so it is there the moment the screen locks.
    private var wallpaperHost: LockWallpaperHost?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var isShowing = false
    var onLockChange: ((Bool) -> Void)?

    init(nowPlaying: NowPlayingService, lyrics: LyricsService) {
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.locked() })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.unlocked() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main) { [weak self] _ in self?.prepareSystemGlass() })
        settings.$lockSystemGlass.combineLatest(settings.$displayID, settings.$lockScreenWidgets)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prepareSystemGlass() }
            .store(in: &subscriptions)
    }

    /// Connects to the lock screen wallpaper ahead of time (or drops it when
    /// the test mode is off), never while the lock screen is showing.
    private func prepareSystemGlass() {
        guard !isShowing else { return }
        guard settings.lockSystemGlass, settings.lockScreenWidgets,
              let screen = NSScreen.islandScreen(preferred: settings.displayID) else {
            wallpaperHost = nil
            return
        }
        if wallpaperHost?.displayID != screen.displayID {
            wallpaperHost = LockWallpaperHost(displayID: screen.displayID, size: screen.frame.size)
        }
    }

    private func locked() {
        onLockChange?(true)
        guard settings.lockScreenWidgets else { return }
        show()
    }

    private func unlocked() {
        onLockChange?(false)
        hide()
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
        if settings.lockSystemGlass {
            if wallpaperHost?.displayID != screen.displayID {
                wallpaperHost = LockWallpaperHost(displayID: screen.displayID, size: screen.frame.size)
            }
        } else {
            wallpaperHost = nil
        }
        if let wallpaper = wallpaperHost {
            // The wallpaper underneath, the SwiftUI content (and its glass) on top.
            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            container.layer?.addSublayer(wallpaper.layer)
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            wallpaper.lockBegan(size: screen.frame.size)
        } else {
            panel.contentView = host
        }
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
        // The glass bends what the lock screen really shows.
        if wallpaperHost == nil { Wallpaper.shared.beginScreenCapture(on: screen) }
        isShowing = true
    }

    func hide() {
        guard isShowing, let panel = window else { return }
        isShowing = false
        Wallpaper.shared.endScreenCapture()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.isShowing == false else { return }
            panel.orderOut(nil)
            panel.contentView = nil
            self?.wallpaperHost?.lockEnded()
            self?.prepareSystemGlass()
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
