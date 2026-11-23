import AppKit
import CoreBluetooth
import SwiftUI

/// A Philips Hue light that is only paired over Bluetooth (no bridge).
///
/// Hue's Bluetooth lights expose a light service (932C32BD-…) with plain
/// characteristics: power (1 byte), brightness (1 byte, 1–254), colour
/// temperature (2 bytes, mired, little endian; FFFF in colour mode) and
/// colour as CIE xy (2 × UInt16 LE scaled to 0xFFFF).
///
/// A light keeps only one Bluetooth connection, so the app connects for a
/// command, stays a few seconds for follow-ups (dragging the slider) and
/// lets go again – the Hue app on the phone keeps working.
final class HueBluetoothLight: NSObject, ObservableObject {
    static let shared = HueBluetoothLight()

    enum Phase: Equatable {
        case bluetoothOff, unauthorized, notPaired, searching, idle, connecting, ready
    }

    @Published private(set) var phase: Phase = .notPaired
    @Published private(set) var name = "Hue"
    @Published private(set) var isOn = false
    /// 0…1.
    @Published private(set) var brightness: Double = 0.5
    /// The light's colour as last set or read (for the UI).
    @Published private(set) var color: Color = Color(red: 1, green: 0.8, blue: 0.55)
    @Published private(set) var hasState = false
    /// What the light shows now, for saving it as a scene.
    @Published private(set) var current: LightMood.Kind?
    /// The light answered the last time the app tried (false when it is out
    /// of reach or switched off at the wall).
    @Published private(set) var reachable = false

    private static let service = CBUUID(string: "932C32BD-0000-47A2-835A-A8D455B859DD")
    private static let advertised = CBUUID(string: "FE0F")
    private static let powerID = CBUUID(string: "932C32BD-0002-47A2-835A-A8D455B859DD")
    private static let brightnessID = CBUUID(string: "932C32BD-0003-47A2-835A-A8D455B859DD")
    private static let temperatureID = CBUUID(string: "932C32BD-0004-47A2-835A-A8D455B859DD")
    private static let colorID = CBUUID(string: "932C32BD-0005-47A2-835A-A8D455B859DD")
    private static let savedKey = "hueLightID"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    /// Writes waiting for the connection, latest per characteristic.
    private var pending: [CBUUID: Data] = [:]
    private var pendingOrder: [CBUUID] = []
    private var disconnectWork: DispatchWorkItem?
    private var searchTimeout: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?

    private var savedID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.savedKey) }
    }

    var isPaired: Bool { savedID != nil }

    /// Starts Bluetooth only when a light is paired or the user searches, so
    /// nobody without a Hue light is asked for Bluetooth because of it.
    func start() {
        guard isPaired else { phase = .notPaired; return }
        ensureCentral()
        refresh()
    }

    private func ensureCentral() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    // MARK: - Commands

    /// Looks for a Hue light that was made discoverable in the Hue app.
    func search() {
        ensureCentral()
        phase = .searching
        startScanIfReady()
        searchTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .searching else { return }
            self.central?.stopScan()
            self.phase = self.isPaired ? .idle : .notPaired
        }
        searchTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func startScanIfReady() {
        guard phase == .searching, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.advertised], options: nil)
    }

    func forget() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        savedID = nil
        hasState = false
        reachable = false
        phase = .notPaired
    }

    /// Reads the light's state (power, brightness, colour).
    func refresh() {
        guard isPaired else { return }
        connect()
    }

    /// What the light shows now, to put back after an effect.
    struct Snapshot {
        let isOn: Bool
        let brightness: Double
        let kind: LightMood.Kind?
    }

    func snapshot() -> Snapshot { Snapshot(isOn: isOn, brightness: brightness, kind: current) }

    func restore(_ snapshot: Snapshot) {
        switch snapshot.kind {
        case .white(let kelvin)?: setWhite(kelvin: kelvin)
        case .color(let hex)?: if let color = NSColor(hex: hex) { setColor(color, switchOn: false) }
        default: break
        }
        setBrightness(snapshot.brightness)
        if !snapshot.isOn { setOn(false) }
    }

    func setOn(_ on: Bool) {
        isOn = on
        send(Self.powerID, Data([on ? 1 : 0]))
    }

    func toggle() { setOn(!isOn) }

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0), 1)
        if !isOn { isOn = true; queue(Self.powerID, Data([1])) }
        send(Self.brightnessID, Data([UInt8(max(1, min(254, (brightness * 253).rounded() + 1)))]))
    }

    /// Any colour; Hue takes its chromaticity, the brightness stays.
    func setColor(_ nsColor: NSColor, switchOn: Bool = true) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return }
        color = Color(nsColor: rgb)
        current = .color(hex: rgb.hexString)
        let (x, y) = Self.xy(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
        let data = Data(le16(UInt16(min(max(x, 0), 1) * 65535)) + le16(UInt16(min(max(y, 0), 1) * 65535)))
        if switchOn, !isOn { isOn = true; queue(Self.powerID, Data([1])) }
        send(Self.colorID, data)
    }

    /// White in Kelvin (2200–6500).
    func setWhite(kelvin: Double) {
        let mired = UInt16(min(max(1_000_000 / kelvin, 153), 500))
        color = Self.whiteColor(kelvin: kelvin)
        current = .white(kelvin: kelvin)
        if !isOn { isOn = true; queue(Self.powerID, Data([1])) }
        send(Self.temperatureID, Data(le16(mired)))
    }

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

    private func send(_ id: CBUUID, _ data: Data) {
        queue(id, data)
        connect()
        flush()
    }

    private func queue(_ id: CBUUID, _ data: Data) {
        pending[id] = data
        pendingOrder.removeAll { $0 == id }
        pendingOrder.append(id)
    }

    private func flush() {
        guard phase == .ready, let peripheral else { return }
        for id in pendingOrder {
            guard let data = pending[id], let characteristic = characteristics[id] else { continue }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        pending.removeAll()
        pendingOrder.removeAll()
        scheduleDisconnect()
    }

    // MARK: - Connection

    private func connect() {
        ensureCentral()
        guard let central, central.state == .poweredOn else { return }
        if phase == .ready { flush(); return }
        guard phase != .connecting else { return }
        if peripheral == nil, let id = savedID {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let peripheral else { phase = .notPaired; return }
        phase = .connecting
        peripheral.delegate = self
        central.connect(peripheral)
        // CoreBluetooth waits forever for a light out of reach.
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connecting else { return }
            central.cancelPeripheralConnection(peripheral)
            self.phase = .idle
            self.reachable = false
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    /// Lets go a few seconds after the last command, for the phone's app.
    private func scheduleDisconnect() {
        disconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let peripheral = self.peripheral else { return }
            self.central?.cancelPeripheralConnection(peripheral)
        }
        disconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: - Colour maths

    /// sRGB → CIE xy (wide gamut D65, as Philips documents it).
    static func xy(r: CGFloat, g: CGFloat, b: CGFloat) -> (Double, Double) {
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let red = linear(r), green = linear(g), blue = linear(b)
        let X = red * 0.664511 + green * 0.154324 + blue * 0.162028
        let Y = red * 0.283881 + green * 0.668433 + blue * 0.047685
        let Z = red * 0.000088 + green * 0.072310 + blue * 0.986039
        let sum = X + Y + Z
        guard sum > 0 else { return (0.3227, 0.329) }
        return (X / sum, Y / sum)
    }

    /// CIE xy → a displayable colour at full brightness.
    static func color(x: Double, y: Double) -> Color {
        guard y > 0 else { return .white }
        let X = x / y, Z = (1 - x - y) / y
        var r = X * 1.656492 - 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + 1.655397 + Z * 0.036152
        var b = X * 0.051713 - 0.121364 + Z * 1.011530
        let top = max(r, g, b, 1e-6)
        r = max(r, 0) / top; g = max(g, 0) / top; b = max(b, 0) / top
        func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return Color(red: gamma(r), green: gamma(g), blue: gamma(b))
    }

    static func whiteColor(kelvin: Double) -> Color {
        // Warm white → daylight, close enough for the swatch.
        let t = min(max((kelvin - 2200) / (6500 - 2200), 0), 1)
        return Color(red: 1, green: 0.72 + 0.26 * t, blue: 0.42 + 0.56 * t)
    }
}

extension HueBluetoothLight: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .searching {
                startScanIfReady()
            } else {
                phase = isPaired ? .idle : .notPaired
                if isPaired { connect() }
            }
        case .unauthorized: phase = .unauthorized
        default: phase = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .searching else { return }
        central.stopScan()
        searchTimeout?.cancel()
        self.peripheral = peripheral
        savedID = peripheral.identifier
        name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Hue"
        phase = .idle
        connect()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let name = peripheral.name { self.name = name }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel()
        phase = .idle
        reachable = false
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristics.removeAll()
        if phase != .notPaired && phase != .searching { phase = .idle }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.powerID, Self.brightnessID, Self.temperatureID, Self.colorID],
                                           for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        connectTimeout?.cancel()
        phase = .ready
        reachable = true
        // The temperature first: it tells whether the light is in colour mode.
        for id in [Self.powerID, Self.brightnessID, Self.temperatureID, Self.colorID] where pending[id] == nil {
            if let characteristic = characteristics[id] { peripheral.readValue(for: characteristic) }
        }
        flush()
        scheduleDisconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let bytes = characteristic.value.map({ [UInt8]($0) }), !bytes.isEmpty else { return }
        hasState = true
        switch characteristic.uuid {
        case Self.powerID: isOn = bytes[0] != 0
        case Self.brightnessID: brightness = Double(max(1, Int(bytes[0])) - 1) / 253
        case Self.temperatureID where bytes.count >= 2:
            let mired = Int(bytes[0]) | Int(bytes[1]) << 8
            if mired != 0xFFFF, mired > 0 {
                let kelvin = (1_000_000 / Double(mired) / 50).rounded() * 50
                color = Self.whiteColor(kelvin: kelvin)
                current = .white(kelvin: kelvin)
            }
        case Self.colorID where bytes.count >= 4:
            // Only when the light is in colour mode (its temperature reads FFFF).
            guard let temperature = characteristics[Self.temperatureID]?.value,
                  [UInt8](temperature) == [0xFF, 0xFF] else { break }
            let x = Double(Int(bytes[0]) | Int(bytes[1]) << 8) / 65535
            let y = Double(Int(bytes[2]) | Int(bytes[3]) << 8) / 65535
            color = Self.color(x: x, y: y)
            current = .color(hex: NSColor(color).hexString)
        default: break
        }
    }
}
