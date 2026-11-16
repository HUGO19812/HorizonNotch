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
    /// Fires when the default output switches to another device (not at launch).
    let deviceChanged = PassthroughSubject<Void, Never>()

    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    private init() {
        refreshDevice()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.refreshDevice()
            self?.deviceChanged.send()
        }
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
