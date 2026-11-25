import AppKit
import Combine
import IOBluetooth

/// The Bluetooth speakers (KRK Kreate 3 and the like) for the speaker tab:
/// connect and disconnect them without the Bluetooth menu, and send the
/// sound to them once they are there. They can't be controlled beyond that
/// – level and EQ sit on their back panel.
///
/// Which device: the one chosen in the tab, else the first paired device
/// whose name says KRK or Kreate.
final class BluetoothSpeaker: NSObject, ObservableObject {
    static let shared = BluetoothSpeaker()

    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published private(set) var name: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var problem: String?
    /// Paired audio devices to choose from when no KRK was found.
    @Published private(set) var candidates: [Candidate] = []

    private var device: IOBluetoothDevice?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var outputWatch: AnyCancellable?
    private static let addressKey = "speakerAddress"

    private override init() {
        super.init()
    }

    /// Looks for the speakers and follows their connection.
    func start() {
        findDevice()
        if connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                             selector: #selector(connected(_:device:)))
        }
    }

    func choose(_ candidate: Candidate) {
        UserDefaults.standard.set(candidate.id, forKey: Self.addressKey)
        findDevice()
    }

    /// Shows the list of paired audio devices to choose again.
    func forget() {
        disconnectNotification?.unregister()
        disconnectNotification = nil
        UserDefaults.standard.set("", forKey: Self.addressKey)
        findDevice()
    }

    private func findDevice() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let saved = UserDefaults.standard.string(forKey: Self.addressKey)
        // "" = the user wants to pick from the list.
        device = saved == "" ? nil
            : paired.first { saved != nil && $0.addressString == saved } ?? paired.first { Self.looksLikeKRK($0.name) }
        name = device?.name
        candidates = paired
            .filter { $0.deviceClassMajor == kBluetoothDeviceClassMajorAudio }
            .compactMap { device in device.name.map { Candidate(id: device.addressString, name: $0) } }
        updateConnection()
    }

    private static func looksLikeKRK(_ name: String?) -> Bool {
        let lower = name?.lowercased() ?? ""
        return lower.contains("krk") || lower.contains("kreate")
    }

    private func updateConnection() {
        let connected = device?.isConnected() ?? false
        if connected != isConnected { isConnected = connected }
        disconnectNotification?.unregister()
        disconnectNotification = connected
            ? device?.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            : nil
    }

    // MARK: Connect

    func toggle() {
        isConnected ? disconnect() : connect()
    }

    func connect() {
        guard let device, !isConnecting else { return }
        problem = nil
        isConnecting = true
        // Asynchronous: the answer comes in connectionComplete(_:status:).
        if device.openConnection(self) != kIOReturnSuccess {
            isConnecting = false
            problem = L("Nicht erreichbar – sind die Boxen an?", "Not reachable – are the speakers on?")
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [self] in
            isConnecting = false
            guard status == kIOReturnSuccess else {
                problem = L("Nicht erreichbar – sind die Boxen an?", "Not reachable – are the speakers on?")
                return
            }
            updateConnection()
            selectAsOutputWhenReady()
        }
    }

    func disconnect() {
        outputWatch = nil
        device?.closeConnection()
        updateConnection()
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.addressString == self.device?.addressString else { return }
        DispatchQueue.main.async { [self] in updateConnection() }
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [self] in
            isConnected = false
            disconnectNotification = nil
        }
    }

    // MARK: Output

    /// The sound plays on the speakers.
    var isOutput: Bool {
        guard isConnected, let name else { return false }
        return AudioOutput.shared.deviceName == name
    }

    func selectAsOutput() {
        guard let name, let target = AudioOutput.shared.devices.first(where: { $0.name == name }) else { return }
        AudioOutput.shared.select(target)
    }

    /// Core Audio lists the speakers a moment after the Bluetooth
    /// connection; then the sound goes there (given up after 15 s).
    private func selectAsOutputWhenReady() {
        guard let name else { return }
        outputWatch = AudioOutput.shared.$devices
            .first { $0.contains { $0.name == name } }
            .timeout(.seconds(15), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.selectAsOutput()
                self?.outputWatch = nil
            }
    }
}
