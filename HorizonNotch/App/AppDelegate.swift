import AppKit
import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("horizon.openSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = NotchCoordinator()
    let nowPlaying = NowPlayingService()
    private(set) lazy var hud = HUDModule()
    private(set) lazy var media = MediaModule(service: nowPlaying)
    let battery = BatteryModule()
    let privacy = PrivacyModule()
    let timer = TimerModule()
    let shelf = ShelfModule()
    let calendar = CalendarModule()
    let weather = WeatherModule()
    let calculator = CalculatorModule()
    let claude = ClaudeCodeModule()
    let downloads = DownloadProgressModule()
    let connectivity = EventModule(id: "connectivity", title: ("Verbindungen", "Connectivity"),
                                   symbol: "dot.radiowaves.left.and.right")
    let notifications = EventModule(id: "notifications", title: ("Benachrichtigungen", "Notifications"),
                                    symbol: "bell.badge.fill")
    private var connectivityMonitor: ConnectivityMonitor?
    private var downloadWatcher: DownloadWatcher?
    private var lockScreen: LockScreenController?

    private var notchController: NotchWindowController?
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        coordinator.register(hud)
        coordinator.register(media)
        coordinator.register(timer)
        coordinator.register(shelf)
        coordinator.register(calendar)
        coordinator.register(weather)
        coordinator.register(calculator)
        coordinator.register(claude)
        coordinator.register(downloads)
        coordinator.register(connectivity)
        coordinator.register(notifications)
        connectivityMonitor = ConnectivityMonitor { [weak self] in self?.connectivity.post($0) }
        downloadWatcher = DownloadWatcher { [weak self] in self?.notifications.post($0) }
        lockScreen = LockScreenController(nowPlaying: nowPlaying)
        coordinator.register(battery)
        coordinator.register(privacy)
        nowPlaying.start()

        let controller = NotchWindowController(coordinator: coordinator, shelf: shelf)
        controller.start()
        notchController = controller
        controller.onMediaSwipe = { [weak self] direction in
            guard let self else { return }
            switch AppSettings.shared.musicGesture {
            case .track: self.nowPlaying.send(direction > 0 ? .next : .previous)
            case .seek:
                if let info = self.nowPlaying.info {
                    self.nowPlaying.seek(to: max(0, info.elapsed(at: Date()) + Double(direction * 10)))
                }
            case .off: break
            }
        }

        statusBar = StatusBarController(appDelegate: self)
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }
        lockScreen?.onLockChange = { [weak controller] _ in controller?.collapse() }

        if !AppSettings.shared.onboardingDone {
            showSettings(tab: .permissions)
        }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    #if DEBUG
    /// Lets scripts drive the island while developing:
    /// `notifyutil` is not enough here, so post a distributed notification
    /// named "horizonnotch.debug" with object "expand", "collapse", "hud",
    /// "plug", "low", "event", "download", "timer", "peek", "lock", "unlock" or
    /// "page:<module id>".
    private func installDebugHooks() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("horizonnotch.debug"),
                                                            object: nil, queue: .main) { [weak self] note in
            switch note.object as? String {
            case "expand": self?.notchController?.expand()
            case "collapse": self?.notchController?.collapse()
            case "hud": self?.hud.debugShow()
            case "plug": self?.battery.debugShow(.pluggedIn)
            case "low": self?.battery.debugShow(.low(9))
            case "peek": self?.media.debugPeek()
            case "caldemo": self?.calendar.debugDemo()
            case "claudedemo": self?.claude.debugDemo()
            case "dldemo": self?.downloads.debugDemo()
            case "settings": NotificationCenter.default.post(name: .openSettings, object: nil)
            case "sidehud":
                AppSettings.shared.hudStyle = .sideBar
                self?.hud.debugShow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppSettings.shared.hudStyle = .notch }
            case "pin": self?.notchController?.debugPinned = true
            case "unpin": self?.notchController?.debugPinned = false
            case "lock": self?.lockScreen?.show()
            case "unlock": self?.lockScreen?.hide()
            case "event":
                self?.connectivity.post(IslandEvent(symbol: "airpodspro", title: "AirPods Pro", detail: "L 80 % · R 85 %"))
            case "download":
                self?.notifications.post(IslandEvent(symbol: "arrow.down.circle.fill", tint: .blue,
                                                     title: "Rechnung-Oktober.pdf", detail: "Geladen"))
            case "timer":
                self?.timer.setDuration(minutes: 1)
                self?.timer.startTimer()
            case let command? where command.hasPrefix("page:"):
                self?.coordinator.showPage(id: String(command.dropFirst(5)))
            default: break
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
    }

    func showSettings(tab: SettingsTab = .general) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(appDelegate: self) }
        notchController?.collapse()
        settingsWindow?.show(tab: tab)
    }

    func toggleIsland() {
        guard let controller = notchController else { return }
        if controller.model.isExpanded { controller.collapse() } else { controller.expand() }
    }

    /// Called after the user granted Accessibility.
    func permissionsChanged() {
        hud.updateTap(enabled: AppSettings.shared.replaceSystemHUD && AppSettings.shared.isEnabled(hud.id))
    }
}
