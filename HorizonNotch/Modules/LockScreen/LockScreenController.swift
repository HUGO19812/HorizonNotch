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
        // The moving wallpaper for Apple's glass (see LiveWallpaperPiece).
        if settings.lockSystemGlass {
            LockWallpaperHost.current = LockWallpaperHost(displayID: screen.displayID, size: screen.frame.size)
        }
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
            LockWallpaperHost.current = nil
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
