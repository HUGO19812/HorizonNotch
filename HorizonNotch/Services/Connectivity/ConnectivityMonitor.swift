import AppKit
import Combine
import CoreWLAN
import Intents
import IOBluetooth
import Network

/// Turns connection changes into island events:
/// - Bluetooth headphones becoming the audio output (no permission needed)
///   and every Bluetooth device with the AirPods battery (opt-in, needs the
///   Bluetooth permission) as a device card
/// - Wi-Fi joined/lost; the network name only if Location is allowed,
///   since macOS hides SSIDs otherwise
/// - Focus on/off (opt-in, needs the Focus permission). macOS has no change
///   notification for Focus, so this one source checks every 20 s.
final class ConnectivityMonitor: NSObject, CWEventDelegate {
    private let post: (IslandEvent) -> Void
    /// Bluetooth devices connecting and disconnecting, as a card.
    private let device: (DeviceCard) -> Void
    private let settings = AppSettings.shared
    private let output = AudioOutput.shared
    private var subscriptions = Set<AnyCancellable>()

    private var lastOutputName: String
    private var lastOutputWasBluetooth: Bool
    private var lastOutputWasKRK: Bool
    private let pathMonitor = NWPathMonitor()
    private var wifiConnected: Bool?
    private var lastSSID: String?
    private var quietUntil = Date().addingTimeInterval(8)
    private var bluetoothConnectNotification: IOBluetoothUserNotification?
    private var focusTimer: Timer?
    private var lastFocused: Bool?

    init(post: @escaping (IslandEvent) -> Void, device: @escaping (DeviceCard) -> Void) {
        self.post = post
        self.device = device
        lastOutputName = AudioOutput.shared.deviceName
        lastOutputWasBluetooth = AudioOutput.shared.isBluetooth
        lastOutputWasKRK = AudioOutput.shared.isKRK
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
            lastOutputWasKRK = output.isKRK
        }
        if output.isBluetooth {
            showCard(symbol: output.symbol, name: name, connected: true, model: output.isKRK ? .speakers : nil)
        } else if lastOutputWasBluetooth {
            showCard(symbol: lastOutputWasKRK ? "hifispeaker.2.fill" : "headphones", name: lastOutputName,
                     connected: false, model: lastOutputWasKRK ? .speakers : nil)
        }
    }

    /// The device card in the island. AirPods report their battery a moment
    /// after connecting, so the card is updated then. Battery levels need
    /// the Bluetooth permission ("All Bluetooth devices" option).
    private func showCard(symbol: String, name: String, connected: Bool, model: CustomDeviceModel? = nil) {
        var card = DeviceCard(name: name, symbol: symbol, connected: connected, model: model)
        guard connected else {
            device(card)
            return
        }
        if settings.connectivityAllBluetooth { Self.fillBattery(&card) }
        device(card)
        guard settings.connectivityAllBluetooth else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            var later = card
            Self.fillBattery(&later)
            if later != card { self?.device(later) }
        }
    }

    private static func fillBattery(_ card: inout DeviceCard) {
        guard let device = connectedDevice(named: card.name) else { return }
        card.left = percent("batteryPercentLeft", of: device)
        card.right = percent("batteryPercentRight", of: device)
        card.caseLevel = percent("batteryPercentCase", of: device)
        card.single = percent("batteryPercentSingle", of: device) ?? percent("batteryPercentCombined", of: device)
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

    /// The Hue light is connected and released by the Light tab for every
    /// command; that is no news worth a card.
    private static func isHueLight(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("hue ") || lower.contains("lightstrip") || name == HueBluetoothLight.shared.name
    }

    @objc private func bluetoothConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:)))
        guard !isQuiet, let name = device.name, name != output.deviceName, !Self.isHueLight(name) else { return }
        showCard(symbol: Self.symbol(for: device), name: name, connected: true)
    }

    @objc private func bluetoothDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        guard !isQuiet, let name = device.name, !Self.isHueLight(name) else { return }
        showCard(symbol: Self.symbol(for: device), name: name, connected: false)
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("keyboard") || name.contains("tastatur") { return "keyboard" }
        if name.contains("mouse") || name.contains("maus") { return "magicmouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("iphone") { return "iphone.gen3.radiowaves.left.and.right" }
        if name.contains("ipad") { return "ipad" }
        switch device.deviceClassMajor {
        case 0x04: return "headphones"            // audio/video
        case 0x05: return "keyboard"              // peripheral
        case 0x02: return "iphone.gen3.radiowaves.left.and.right" // phone
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// A battery percentage via undocumented IOBluetoothDevice properties.
    private static func percent(_ key: String, of device: IOBluetoothDevice) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 else { return nil }
        return value.intValue
    }

    private static func connectedDevice(named name: String) -> IOBluetoothDevice? {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.first { $0.isConnected() && $0.name == name }
    }

    // MARK: - Wi-Fi

    private var lastWasHotspot = false

    private func pathChanged(_ path: NWPath) {
        let connected = path.status == .satisfied && path.usesInterfaceType(.wifi)
        // An iPhone's Personal Hotspot marks the network as expensive.
        let hotspot = connected && path.isExpensive
        defer { wifiConnected = connected; lastWasHotspot = hotspot }
        guard let previous = wifiConnected, previous != connected, !isQuiet else {
            if wifiConnected == nil { lastSSID = CWWiFiClient.shared().interface()?.ssid() }
            return
        }
        if connected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                let ssid = CWWiFiClient.shared().interface()?.ssid()
                self?.lastSSID = ssid
                if hotspot {
                    self?.post(IslandEvent(symbol: "personalhotspot", tint: .green, title: ssid ?? "Hotspot",
                                           detail: L("Hotspot verbunden", "Hotspot connected")))
                } else {
                    self?.post(IslandEvent(symbol: "wifi", tint: .blue, title: ssid ?? "WLAN",
                                           detail: L("Verbunden", "Connected")))
                }
            }
        } else {
            let wasHotspot = lastWasHotspot
            post(IslandEvent(symbol: wasHotspot ? "personalhotspot.slash" : "wifi.slash", tint: .white.opacity(0.6),
                             title: lastSSID ?? (wasHotspot ? "Hotspot" : "WLAN"), detail: L("Getrennt", "Disconnected")))
        }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ssid = CWWiFiClient.shared().interface(withName: interfaceName)?.ssid()
            defer { if ssid != nil { self.lastSSID = ssid } }
            // Joining from "no Wi-Fi" is reported by the path monitor.
            guard let ssid, let previous = self.lastSSID, ssid != previous, self.wifiConnected == true, !self.isQuiet else { return }
            let hotspot = self.lastWasHotspot
            self.post(IslandEvent(symbol: hotspot ? "personalhotspot" : "wifi", tint: hotspot ? .green : .blue,
                                  title: ssid, detail: L("Gewechselt", "Switched")))
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
