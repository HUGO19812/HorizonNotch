import AppKit
import Combine
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
    let clipboard = ClipboardModule()
    private var rainSubscription: AnyCancellable?
    private var lastRainNotice: Date?
    let calendar = CalendarModule()
    let weather = WeatherModule()
    let calculator = CalculatorModule()
    let claude = ClaudeCodeModule()
    let downloads = DownloadProgressModule()
    let devices = DeviceCardModule()
    let connectivity = EventModule(id: "connectivity", title: ("Verbindungen", "Connectivity"),
                                   symbol: "dot.radiowaves.left.and.right")
    let notifications = EventModule(id: "notifications", title: ("Benachrichtigungen", "Notifications"),
                                    symbol: "bell.badge.fill")
    private var connectivityMonitor: ConnectivityMonitor?
    private var downloadWatcher: DownloadWatcher?
    private var lockScreen: LockScreenController?
    private(set) var screenSaver: ScreenSaverController?

    private var notchController: NotchWindowController?
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    /// Only one Horizon Notch at a time: two would draw two islands and
    /// fight over the keys. The copy started last wins (e.g. a fresh build).
    private func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where other != NSRunningApplication.current {
            other.terminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        quitOtherCopies()
        Updater.shared.start()

        coordinator.register(hud)
        coordinator.register(media)
        coordinator.register(timer)
        coordinator.register(shelf)
        coordinator.register(clipboard)
        coordinator.register(calendar)
        coordinator.register(weather)
        coordinator.register(calculator)
        coordinator.register(claude)
        coordinator.register(downloads)
        coordinator.register(connectivity)
        coordinator.register(devices)
        coordinator.register(notifications)
        connectivityMonitor = ConnectivityMonitor(post: { [weak self] in self?.connectivity.post($0) },
                                                  device: { [weak self] in self?.devices.show($0) })
        downloadWatcher = DownloadWatcher { [weak self] in self?.notifications.post($0) }
        lockScreen = LockScreenController(nowPlaying: nowPlaying, lyrics: media.lyrics)
        LockScreenSources.weather = weather.service
        // "Rain in 15 min" as a short notice, once per shower.
        weather.service.activateForAlerts()
        rainSubscription = weather.service.$report
            .compactMap { $0?.rainStart }
            .removeDuplicates()
            .sink { [weak self] start in
                guard let self, AppSettings.shared.weatherRainAlert else { return }
                if let last = self.lastRainNotice, abs(last.timeIntervalSince(start)) < 3 * 3600 { return }
                self.lastRainNotice = start
                let minutes = max(5, Int(start.timeIntervalSinceNow / 60 / 5) * 5)
                self.notifications.post(IslandEvent(symbol: "cloud.rain.fill", tint: .cyan,
                                                    title: L("Regen in \(minutes) Min.", "Rain in \(minutes) min"),
                                                    detail: L("Schirm nicht vergessen", "Take an umbrella"),
                                                    duration: 6))
            }
        screenSaver = ScreenSaverController(nowPlaying: nowPlaying, lyrics: media.lyrics)
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
            case .off, .tabs: break
            }
        }

        statusBar = StatusBarController(appDelegate: self)
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }
        lockScreen?.onLockChange = { [weak controller, weak self] locked in
            controller?.collapse()
            self?.screenSaver?.screenLocked(locked)
        }

        OnboardingActions.requestCalendar = { [weak self] in self?.calendar.requestAccess() }
        OnboardingActions.requestLocation = { [weak self] in self?.weather.service.activate() }
        OnboardingActions.accessibilityChanged = { [weak self] in self?.permissionsChanged() }
        if !AppSettings.shared.onboardingDone {
            // Say hello in the notch, then ask for each permission there,
            // one step at a time; the island stays open until "Done".
            controller.model.showHello = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.expand() }
            NotificationCenter.default.addObserver(forName: .helloFinished, object: nil, queue: .main) { [weak controller] _ in
                controller?.model.showHello = false
                controller?.collapse()
                AppSettings.shared.onboardingDone = true
            }
        }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    #if DEBUG
    /// Lets scripts drive the island while developing:
    /// `notifyutil` is not enough here, so post a distributed notification
    /// named "horizonnotch.debug" with object "expand", "collapse", "hud", "bluetooth",
    /// "plug", "low", "event", "download", "timer", "peek", "lock", "unlock" or
    /// "page:<module id>".
    private func installDebugHooks() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("horizonnotch.debug"),
                                                            object: nil, queue: .main) { [weak self] note in
            switch note.object as? String {
            case "expand": self?.notchController?.expand()
            case "collapse": self?.notchController?.collapse()
            case "hud": self?.hud.debugShow()
            case "bluetooth": self?.devices.show(DeviceCard(name: "AirPods Pro", symbol: "airpodspro", connected: true,
                                                            left: 85, right: 80, caseLevel: 60, single: nil))
            case "plug": self?.battery.debugShow(.pluggedIn)
            case "low": self?.battery.debugShow(.low(9))
            case "peek": self?.media.debugPeek()
            case "caldemo": self?.calendar.debugDemo()
            case "claudedemo": self?.claude.debugDemo()
            case "dldemo": self?.downloads.debugDemo()
            case "settings": NotificationCenter.default.post(name: .openSettings, object: nil)
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
