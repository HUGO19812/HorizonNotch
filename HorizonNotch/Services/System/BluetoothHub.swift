import AppKit
import Combine
import IOBluetooth

/// All paired Bluetooth devices for the Bluetooth tab: which are connected,
/// their battery where the device reports one, and connecting or
/// disconnecting them with a click – without the Bluetooth menu. Audio
/// devices (KRK speakers, headphones) take over the sound once connected.
final class BluetoothHub: NSObject, ObservableObject {
    static let shared = BluetoothHub()

    struct Device: Identifiable, Equatable {
        /// The Bluetooth address.
        let id: String
        let name: String
        let symbol: String
        let isConnected: Bool
        let isAudio: Bool
        /// Per cent, when the device tells.
        let battery: Int?
    }

    @Published private(set) var devices: [Device] = []
    /// Addresses being connected right now.
    @Published private(set) var connecting: Set<String> = []
    /// The address of a device that could not be reached.
    @Published private(set) var unreachable: String?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var outputWatch: AnyCancellable?

    private override init() {
        super.init()
    }

    /// Reads the paired devices and follows their connections. Called when
    /// the tab opens, so Bluetooth is asked only then.
    func start() {
        refresh()
        if connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                             selector: #selector(connected(_:device:)))
        }
    }

    func refresh() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devices = paired.compactMap { device -> Device? in
            guard let name = device.name, let address = device.addressString else { return nil }
            let connected = device.isConnected()
            if connected, disconnectNotifications[address] == nil {
                disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                                   selector: #selector(disconnected(_:device:)))
            }
            return Device(id: address, name: name, symbol: Self.symbol(for: device, name: name),
                          isConnected: connected, isAudio: Int(device.deviceClassMajor) == kBluetoothDeviceClassMajorAudio,
                          battery: connected ? Self.battery(of: device) : nil)
        }
        // Connected first, then by name.
        .sorted { ($0.isConnected ? 0 : 1, $0.name.lowercased()) < ($1.isConnected ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Connect

    func toggle(_ device: Device) {
        device.isConnected ? disconnect(device) : connect(device)
    }

    func connect(_ device: Device) {
        guard let bluetooth = IOBluetoothDevice(addressString: device.id), !connecting.contains(device.id) else { return }
        if unreachable == device.id { unreachable = nil }
        connecting.insert(device.id)
        // Asynchronous: the answer comes in connectionComplete(_:status:).
        if bluetooth.openConnection(self) != kIOReturnSuccess {
            failed(device.id)
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let address = device?.addressString ?? ""
        let name = device?.name
        let audio = device.map { Int($0.deviceClassMajor) == kBluetoothDeviceClassMajorAudio } ?? false
        DispatchQueue.main.async { [self] in
            guard status == kIOReturnSuccess else { failed(address); return }
            connecting.remove(address)
            refresh()
            if audio, let name { sendSoundWhenReady(to: name) }
        }
    }

    private func failed(_ address: String) {
        connecting.remove(address)
        unreachable = address
    }

    func disconnect(_ device: Device) {
        IOBluetoothDevice(addressString: device.id)?.closeConnection()
        refresh()
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [self] in refresh() }
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        DispatchQueue.main.async { [self] in
            disconnectNotifications[address] = nil
            refresh()
        }
    }

    // MARK: Sound

    /// The sound plays on this device.
    func isOutput(_ device: Device) -> Bool {
        device.isConnected && AudioOutput.shared.deviceName == device.name
    }

    /// Core Audio lists a device a moment after the Bluetooth connection;
    /// then the sound goes there (given up after 15 s).
    private func sendSoundWhenReady(to name: String) {
        outputWatch = AudioOutput.shared.$devices
            .first { $0.contains { $0.name == name } }
            .timeout(.seconds(15), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                if let target = devices.first(where: { $0.name == name }) { AudioOutput.shared.select(target) }
                self?.outputWatch = nil
            }
    }

    // MARK: Looks

    private static func symbol(for device: IOBluetoothDevice, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("krk") || lower.contains("kreate") { return "hifispeaker.2.fill" }
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if lower.contains("mouse") || lower.contains("maus") { return "magicmouse.fill" }
        if lower.contains("keyboard") || lower.contains("tastatur") { return "keyboard.fill" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("watch") { return "applewatch" }
        if lower.contains("controller") || lower.contains("dualsense") || lower.contains("xbox") { return "gamecontroller.fill" }
        if lower.contains("hue") || lower.contains("lightstrip") { return "lightbulb.led.wide.fill" }
        switch Int(device.deviceClassMajor) {
        case kBluetoothDeviceClassMajorAudio:
            // Minor class 0x01/0x02 = headset, 0x06 = headphones; the rest
            // are speakers of some kind.
            return [0x01, 0x02, 0x06].contains(Int(device.deviceClassMinor)) ? "headphones" : "hifispeaker.fill"
        case kBluetoothDeviceClassMajorPeripheral:
            let minor = Int(device.deviceClassMinor)
            if minor & 0x10 != 0 { return "keyboard.fill" }
            if minor & 0x20 != 0 { return "computermouse.fill" }
            return "gamecontroller.fill"
        case kBluetoothDeviceClassMajorPhone: return "iphone"
        case kBluetoothDeviceClassMajorComputer: return "laptopcomputer"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// The device's battery via undocumented IOBluetoothDevice properties
    /// (as in ConnectivityMonitor); for earbuds the lower side.
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        func percent(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 else { return nil }
            return value.intValue
        }
        if let single = percent("batteryPercentSingle") ?? percent("batteryPercentCombined") { return single }
        let sides = [percent("batteryPercentLeft"), percent("batteryPercentRight")].compactMap { $0 }
        return sides.min()
    }
}
