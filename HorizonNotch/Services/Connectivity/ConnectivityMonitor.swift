import AppKit
import Combine
import CoreWLAN
import Intents
import IOBluetooth
import Network

/// Turns connection changes into island events:
/// - Bluetooth headphones becoming the audio output (no permission needed)
/// - every Bluetooth device and the AirPods battery (opt-in, needs the
///   Bluetooth permission)
/// - Wi-Fi joined/lost; the network name only if Location is allowed,
///   since macOS hides SSIDs otherwise
/// - Focus on/off (opt-in, needs the Focus permission). macOS has no change
///   notification for Focus, so this one source checks every 20 s.
final class ConnectivityMonitor: NSObject, CWEventDelegate {
    private let post: (IslandEvent) -> Void
    private let settings = AppSettings.shared
    private let output = AudioOutput.shared
    private var subscriptions = Set<AnyCancellable>()

    private var lastOutputName: String
    private var lastOutputWasBluetooth: Bool
    private let pathMonitor = NWPathMonitor()
    private var wifiConnected: Bool?
    private var lastSSID: String?
    private var quietUntil = Date().addingTimeInterval(8)
    private var bluetoothConnectNotification: IOBluetoothUserNotification?
    private var focusTimer: Timer?
    private var lastFocused: Bool?

    init(post: @escaping (IslandEvent) -> Void) {
        self.post = post
        lastOutputName = AudioOutput.shared.deviceName
        lastOutputWasBluetooth = AudioOutput.shared.isBluetooth
        super.init()

        output.deviceChanged
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.outputChanged() }
            .store(in: &subscriptions)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "horizon.path"))

        let wifi = CWWiFiClient.shared()
        wifi.delegate = self
        try? wifi.startMonitoringEvent(with: .ssidDidChange)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.quietUntil = Date().addingTimeInterval(10) }
            .store(in: &subscriptions)

        settings.$connectivityAllBluetooth
            .sink { [weak self] on in DispatchQueue.main.async { self?.setBluetoothMonitoring(on) } }
            .store(in: &subscriptions)
        settings.$connectivityFocus
            .sink { [weak self] on in DispatchQueue.main.async { self?.setFocusMonitoring(on) } }
            .store(in: &subscriptions)
    }

    private var isQuiet: Bool { Date() < quietUntil }

    // MARK: - Audio output

    private func outputChanged() {
        let name = output.deviceName
        guard name != lastOutputName else { return }
        defer {
            lastOutputName = name
            lastOutputWasBluetooth = output.isBluetooth
        }
        if output.isBluetooth {
            if settings.connectionStyle == .sideBar {
                showInSideBar(symbol: output.symbol, name: name, connected: true)
                return
            }
            var event = IslandEvent(symbol: output.symbol, tint: .white, title: name,
                                    detail: L("Verbunden", "Connected"))
            if settings.connectivityAllBluetooth, let battery = Self.batteryText(forDeviceNamed: name) {
                event.detail = battery
                event.tint = .green
            }
            post(event)
            // AirPods report their levels a moment after connecting.
            if settings.connectivityAllBluetooth {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let battery = Self.batteryText(forDeviceNamed: name) else { return }
                    self?.post(IslandEvent(symbol: AudioOutput.shared.symbol, tint: .green, title: name, detail: battery))
                }
            }
        } else if lastOutputWasBluetooth {
            if settings.connectionStyle == .sideBar {
                SideHUDController.shared.show(device: .init(symbol: "headphones", battery: nil, connected: false))
                return
            }
            post(IslandEvent(symbol: "headphones", tint: .white.opacity(0.6), title: lastOutputName,
                             detail: L("Getrennt", "Disconnected")))
        }
    }

    /// The device as a bar at the left edge; AirPods report their battery
    /// a moment after connecting, so the bar is shown again then.
    private func showInSideBar(symbol: String, name: String, connected: Bool) {
        let side = SideHUDController.shared
        side.show(device: .init(symbol: symbol, battery: Self.batteryLevel(forDeviceNamed: name), connected: connected))
        guard connected else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let battery = Self.batteryLevel(forDeviceNamed: name) else { return }
            side.show(device: .init(symbol: symbol, battery: battery, connected: true))
        }
    }

    // MARK: - Bluetooth (opt-in)

    private func setBluetoothMonitoring(_ on: Bool) {
        if on, bluetoothConnectNotification == nil {
            // Registering reports every device that is already connected.
            quietUntil = max(quietUntil, Date().addingTimeInterval(3))
            bluetoothConnectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                                      selector: #selector(bluetoothConnected(_:device:)))
        } else if !on {
            bluetoothConnectNotification?.unregister()
            bluetoothConnectNotification = nil
        }
    }

    @objc private func bluetoothConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:)))
        guard !isQuiet, let name = device.name, name != output.deviceName else { return }
        if settings.connectionStyle == .sideBar {
            showInSideBar(symbol: Self.symbol(for: device), name: name, connected: true)
            return
        }
        post(IslandEvent(symbol: Self.symbol(for: device), title: name,
                         detail: Self.batteryText(for: device) ?? L("Verbunden", "Connected")))
    }

    @objc private func bluetoothDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        guard !isQuiet, let name = device.name else { return }
        if settings.connectionStyle == .sideBar {
            SideHUDController.shared.show(device: .init(symbol: Self.symbol(for: device), battery: nil, connected: false))
            return
        }
        post(IslandEvent(symbol: Self.symbol(for: device), tint: .white.opacity(0.6), title: name,
                         detail: L("Getrennt", "Disconnected")))
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("keyboard") || name.contains("tastatur") { return "keyboard" }
        if name.contains("mouse") || name.contains("maus") { return "magicmouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        switch device.deviceClassMajor {
        case 0x04: return "headphones"            // audio/video
        case 0x05: return "keyboard"              // peripheral
        case 0x02: return "iphone"                // phone
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// A battery percentage via undocumented IOBluetoothDevice properties.
    private static func percent(_ key: String, of device: IOBluetoothDevice) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 else { return nil }
        return value.intValue
    }

    /// AirPods/Beats battery via undocumented IOBluetoothDevice properties.
    private static func batteryText(for device: IOBluetoothDevice) -> String? {
        func percent(_ key: String) -> Int? { Self.percent(key, of: device) }
        if let left = percent("batteryPercentLeft"), let right = percent("batteryPercentRight") {
            var text = "L \(left) % · R \(right) %"
            if let box = percent("batteryPercentCase") { text += " · ▢ \(box) %" }
            return text
        }
        if let single = percent("batteryPercentSingle") ?? percent("batteryPercentCombined") { return "\(single) %" }
        return nil
    }

    private static func batteryText(forDeviceNamed name: String) -> String? {
        connectedDevice(named: name).flatMap(batteryText(for:))
    }

    /// Battery 0…1 for the bar: the emptier earbud, else the single value.
    private static func batteryLevel(forDeviceNamed name: String) -> Float? {
        guard let device = connectedDevice(named: name) else { return nil }
        let earbuds = ["batteryPercentLeft", "batteryPercentRight"].compactMap { percent($0, of: device) }
        let value = earbuds.min() ?? percent("batteryPercentSingle", of: device) ?? percent("batteryPercentCombined", of: device)
        return value.map { Float($0) / 100 }
    }

    private static func connectedDevice(named name: String) -> IOBluetoothDevice? {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.first { $0.isConnected() && $0.name == name }
    }

    // MARK: - Wi-Fi

    private func pathChanged(_ path: NWPath) {
        let connected = path.status == .satisfied && path.usesInterfaceType(.wifi)
        defer { wifiConnected = connected }
        guard let previous = wifiConnected, previous != connected, !isQuiet else {
            if wifiConnected == nil { lastSSID = CWWiFiClient.shared().interface()?.ssid() }
            return
        }
        if connected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                let ssid = CWWiFiClient.shared().interface()?.ssid()
                self?.lastSSID = ssid
                self?.post(IslandEvent(symbol: "wifi", tint: .blue, title: ssid ?? "WLAN",
                                       detail: L("Verbunden", "Connected")))
            }
        } else {
            post(IslandEvent(symbol: "wifi.slash", tint: .white.opacity(0.6), title: lastSSID ?? "WLAN",
                             detail: L("Getrennt", "Disconnected")))
        }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ssid = CWWiFiClient.shared().interface(withName: interfaceName)?.ssid()
            defer { if ssid != nil { self.lastSSID = ssid } }
            // Joining from "no Wi-Fi" is reported by the path monitor.
            guard let ssid, let previous = self.lastSSID, ssid != previous, self.wifiConnected == true, !self.isQuiet else { return }
            self.post(IslandEvent(symbol: "wifi", tint: .blue, title: ssid, detail: L("Gewechselt", "Switched")))
        }
    }

    // MARK: - Focus (opt-in)

    private func setFocusMonitoring(_ on: Bool) {
        focusTimer?.invalidate()
        focusTimer = nil
        lastFocused = nil
        guard on else { return }
        let center = INFocusStatusCenter.default
        let start = { [weak self] in
            guard let self, center.authorizationStatus == .authorized else { return }
            self.lastFocused = center.focusStatus.isFocused
            let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkFocus() }
            timer.tolerance = 10
            self.focusTimer = timer
        }
        if center.authorizationStatus == .notDetermined {
            center.requestAuthorization { _ in DispatchQueue.main.async(execute: start) }
        } else {
            start()
        }
    }

    private func checkFocus() {
        guard let focused = INFocusStatusCenter.default.focusStatus.isFocused, focused != lastFocused else { return }
        lastFocused = focused
        post(IslandEvent(symbol: focused ? "moon.fill" : "moon", tint: .indigo,
                         title: L("Fokus", "Focus"), detail: focused ? L("Ein", "On") : L("Aus", "Off")))
    }
}
