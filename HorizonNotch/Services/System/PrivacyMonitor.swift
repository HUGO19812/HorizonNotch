import AppKit
import Combine
import CoreAudio
import CoreMediaIO

/// Watches whether any camera or microphone is in use, and which apps
/// record audio. Purely listener based: CoreAudio process objects
/// (macOS 14.2+) for the microphone, CoreMediaIO for cameras.
/// macOS offers no API that names the app using the camera.
final class PrivacyMonitor: ObservableObject {
    @Published private(set) var cameraActive = false
    @Published private(set) var microphoneApps: [NSRunningApplication] = []
    @Published private(set) var microphoneActive = false

    private var observedProcesses = Set<AudioObjectID>()
    private var observedCameras = Set<CMIOObjectID>()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        var processList = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processList, .main) { [weak self] _, _ in
            self?.refreshProcesses()
        }
        refreshProcesses()

        var devices = Self.cmioAddress(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devices, .main) { [weak self] _, _ in
            self?.refreshCameras()
        }
        refreshCameras()
    }

    // MARK: - Microphone

    private func refreshProcesses() {
        let processes: [AudioObjectID] = Self.array(of: AudioObjectID(kAudioObjectSystemObject),
                                                    selector: kAudioHardwarePropertyProcessObjectList)
        for process in processes where !observedProcesses.contains(process) {
            observedProcesses.insert(process)
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(process, &address, .main) { [weak self] _, _ in
                self?.evaluateMicrophone()
            }
        }
        observedProcesses.formIntersection(processes)
        evaluateMicrophone()
    }

    private func evaluateMicrophone() {
        var apps: [NSRunningApplication] = []
        var anyInput = false
        for process in observedProcesses {
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr, running != 0 else { continue }
            var pid = pid_t(0)
            size = UInt32(MemoryLayout<pid_t>.size)
            address = Self.address(kAudioProcessPropertyPID)
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
            // Only apps count. System daemons such as corespeechd ("Hey
            // Siri") keep the microphone open all the time; macOS shows no
            // indicator for them either. Menu bar apps (e.g. dictation
            // tools) are apps and do count.
            guard pid != ownPID, let app = MediaAppResolver.app(for: pid) else { continue }
            anyInput = true
            if !apps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                apps.append(app)
            }
        }
        if anyInput != microphoneActive { microphoneActive = anyInput }
        if apps.map(\.processIdentifier) != microphoneApps.map(\.processIdentifier) { microphoneApps = apps }
    }

    // MARK: - Camera

    private func refreshCameras() {
        let cameras: [CMIOObjectID] = Self.cmioArray(of: CMIOObjectID(kCMIOObjectSystemObject),
                                                     selector: kCMIOHardwarePropertyDevices)
        for camera in cameras where !observedCameras.contains(camera) {
            observedCameras.insert(camera)
            var address = Self.cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectAddPropertyListenerBlock(camera, &address, .main) { [weak self] _, _ in
                self?.evaluateCameras()
            }
        }
        observedCameras.formIntersection(cameras)
        evaluateCameras()
    }

    private func evaluateCameras() {
        let active = observedCameras.contains { camera in
            var address = Self.cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            var running = UInt32(0)
            var used = UInt32(0)
            let status = CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return status == noErr && running != 0
        }
        if active != cameraActive { cameraActive = active }
    }

    // MARK: - Helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func array(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else { return [] }
        return items
    }

    private static func cmioArray(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var address = cmioAddress(selector)
        var size = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &items) == noErr else { return [] }
        return items
    }
}
