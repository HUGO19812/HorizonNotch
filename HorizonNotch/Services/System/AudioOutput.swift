import AudioToolbox
import Combine
import CoreAudio

/// Default output device: name, kind, volume and mute via CoreAudio.
/// Device changes arrive through a property listener, not polling.
final class AudioOutput: ObservableObject {
    static let shared = AudioOutput()

    @Published private(set) var deviceName = ""
    @Published private(set) var symbol = "hifispeaker.fill"
    @Published private(set) var isBluetooth = false
    /// The output is a KRK speaker, whatever its name ("K3" …): by the
    /// maker's Bluetooth vendor ID in Core Audio's model UID, or the name.
    @Published private(set) var isKRK = false
    private static let krkVendorID = 0x05D6
    /// Fires when the default output switches to another device (not at launch).
    let deviceChanged = PassthroughSubject<Void, Never>()

    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    /// An output the sound can go to.
    struct Device: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let symbol: String
    }

    /// Every device with outputs, for the picker; kept current while
    /// devices come and go.
    @Published private(set) var devices: [Device] = []
    var currentID: AudioObjectID { deviceID }

    private init() {
        refreshDevice()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refreshDevice()
            self?.deviceChanged.send()
        }
        refreshDevices()
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, .main) { [weak self] _, _ in
            self?.refreshDevices()
        }
    }

    /// Sends the sound to another device (like the Sound menu does).
    func select(_ device: Device) {
        var id = device.id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    private func refreshDevices() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return }
        devices = ids.compactMap { id in
            // Only devices that play sound, not microphones or hidden aggregates.
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0
            else { return nil }
            let transport = Self.uint32(id, kAudioDevicePropertyTransportType)
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual {
                return nil
            }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            guard let text = name?.takeRetainedValue() as String?, !text.isEmpty else { return nil }
            return Device(id: id, name: text, symbol: Self.symbol(name: text, transport: transport))
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    // MARK: - Volume

    /// When this is false the volume keys go to macOS, which then shows its
    /// own overlay – so look for every way the device takes a volume.
    var canSetVolume: Bool { !volumeAddresses.isEmpty }

    var volume: Float {
        get {
            guard var address = volumeAddresses.first else { return 0 }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            return value
        }
        set {
            var value = Float32(min(max(newValue, 0), 1))
            for var address in volumeAddresses {
                AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            }
        }
    }

    /// The virtual main volume, or – for devices without one, e.g. some
    /// Bluetooth headsets in the first moments after connecting – the left
    /// and right channel volumes.
    private var volumeAddresses: [AudioObjectPropertyAddress] {
        if deviceID == kAudioObjectUnknown { refreshDevice() }
        var main = volumeAddress
        if isSettable(&main) { return [main] }
        return [UInt32(1), 2].compactMap { channel in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: channel)
            return isSettable(&address) ? address : nil
        }
    }

    private func isSettable(_ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    var isMuted: Bool {
        get {
            var address = muteAddress
            guard AudioObjectHasProperty(deviceID, &address) else { return false }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            return value != 0
        }
        set {
            var address = muteAddress
            guard AudioObjectHasProperty(deviceID, &address) else { return }
            var value = UInt32(newValue ? 1 : 0)
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }

    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Device

    private func refreshDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        deviceID = id

        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &name)
        deviceName = (name?.takeRetainedValue() as String?) ?? ""

        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &size, &transport)
        symbol = Self.symbol(name: deviceName, transport: transport)
        isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE

        // Bluetooth devices report "<product> <vendor>" in hex, e.g. "a 5d6".
        var modelAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyModelUID,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        var model: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &modelAddress, 0, nil, &size, &model)
        let modelUID = (model?.takeRetainedValue() as String?) ?? ""
        let vendor = modelUID.split(separator: " ").last.flatMap { Int($0, radix: 16) }
        isKRK = (isBluetooth && vendor == Self.krkVendorID) || deviceName.lowercased().contains("krk")
        if isKRK { symbol = "hifispeaker.2.fill" }
    }

    private static func symbol(name: String, transport: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("kopfhörer") || lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        default: return "hifispeaker.fill"
        }
    }
}
