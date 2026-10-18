import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

/// The lock screen's large player as a screen saver: after a few idle
/// minutes while music plays it fills the screen; any key, click or mouse
/// move ends it.
///
/// A real .saver bundle runs sandboxed inside macOS' screen saver host and
/// cannot reach the now-playing session, so this is a window of the app.
/// Like the system screen saver it stays away while an app keeps the
/// display awake (videos), while the screen is locked or in full screen.
final class ScreenSaverController {
    private let nowPlaying: NowPlayingService
    private let lyrics: LyricsService
    private let settings = AppSettings.shared
    private let state = LockScreenState()
    private var window: NSWindow?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var subscriptions = Set<AnyCancellable>()
    private var isLocked = false
    private(set) var isShowing = false

    init(nowPlaying: NowPlayingService, lyrics: LyricsService) {
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        settings.$screenSaverEnabled
            .sink { [weak self] enabled in DispatchQueue.main.async { self?.setTimer(enabled) } }
            .store(in: &subscriptions)
        // Music stopped: nothing left to show.
        nowPlaying.$info
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .sink { [weak self] playing in if !playing { self?.hide() } }
            .store(in: &subscriptions)
    }

    /// Called by the lock screen controller.
    func screenLocked(_ locked: Bool) {
        isLocked = locked
        if locked { hide() }
    }

    private func setTimer(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else {
            hide()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 3
    }

    private func tick() {
        guard !isShowing, shouldStart else { return }
        show()
    }

    private var shouldStart: Bool {
        guard settings.screenSaverEnabled, !isLocked,
              nowPlaying.info?.isPlaying == true,
              !FullscreenMonitor.shared.isFullscreen,
              !Self.displayKeptAwake else { return false }
        // Seconds since the last key, click or mouse move anywhere.
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return idle >= settings.screenSaverDelay * 60
    }

    /// An app (a video player, a browser playing a video, a presentation)
    /// asks to keep the display on – the system screen saver waits then too.
    private static var displayKeptAwake: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Any] else { return false }
        let count = (dict["PreventUserIdleDisplaySleep"] as? Int ?? 0) + (dict["NoDisplaySleepAssertion"] as? Int ?? 0)
        return count > 0
    }

    // MARK: - Window

    /// Also used by the "Preview" button in the settings.
    func show() {
        guard !isShowing, let screen = NSScreen.islandScreen(preferred: settings.displayID),
              nowPlaying.info != nil else { return }
        state.large = true
        state.lyrics = settings.screenSaverLyrics
        if state.lyrics, let info = nowPlaying.info { lyrics.load(for: info) }
        let window = self.window ?? makeWindow()
        window.setFrame(screen.frame, display: true)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSCursor.setHiddenUntilMouseMoves(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.8
            window.animator().alphaValue = 1
        }
        isShowing = true
        // Ignore the input that may still be in flight right now (the
        // preview click), then end on the next one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.installMonitors() }
    }

    func hide() {
        guard isShowing, let window else { return }
        isShowing = false
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.isShowing == false { window.orderOut(nil) }
        })
    }

    private func installMonitors() {
        guard isShowing, monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .keyDown, .scrollWheel, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.hide() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.hide()
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // Clicks end the screen saver instead of hitting the buttons.
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: LockScreenView(nowPlaying: nowPlaying, lyrics: lyrics, state: state))
        host.sizingOptions = []
        window.contentView = host
        self.window = window
        return window
    }
}
