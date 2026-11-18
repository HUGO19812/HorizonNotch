import AudioToolbox
import CoreAudio
import Foundation

/// How loud the Mac's audio is right now, so the dot and the bars beside
/// the notch move with the music. Uses a Core Audio process tap on the
/// whole system output (macOS 14.2+): only levels are computed from the
/// samples, nothing is recorded or kept. macOS asks once for "system audio
/// recording" and shows its recording indicator while the tap runs, so it
/// only runs while a view needs it (see `acquire` / `release`).
final class AudioLevelMeter {
    static let shared = AudioLevelMeter()

    struct Levels {
        /// Bass, low mids, high mids, treble, each 0…1 (auto-levelled).
        var bands: [Float] = [0, 0, 0, 0]
        /// Overall loudness 0…1.
        var level: Float = 0
        /// A kick on each beat: jumps up on a sudden rise, then falls off.
        var beat: Float = 0
        /// Real sound arrived lately. False while silent, before the first
        /// buffer, or when the permission was refused (macOS then delivers
        /// silence); views fall back to their decorative animation.
        var hasSignal = false
    }

    /// The latest levels; cheap to read from any thread.
    var levels: Levels { lock.withLock { current } }

    private let lock = NSLock()
    private var current = Levels()
    private var users = 0
    private let queue = DispatchQueue(label: "horizon.audiolevel", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Analysis state, only touched on `queue`.
    private var filters: [Float] = [0, 0, 0]
    private var coefficients: [Float] = [0, 0, 0]
    private var smoothed: [Float] = [0, 0, 0, 0]
    private var peaks: [Float] = [0.02, 0.02, 0.02, 0.02]
    private var levelPeak: Float = 0.02
    private var level: Float = 0
    private var average: Float = 0
    private var beat: Float = 0
    private var silentBuffers = 0

    /// Starts measuring for one more viewer. Main thread.
    func acquire() {
        users += 1
        if users == 1 { start() }
    }

    /// Stops when the last viewer is gone. Main thread.
    func release() {
        users = max(0, users - 1)
        if users == 0 { stop() }
    }

    // MARK: - Tap

    private func start() {
        guard #available(macOS 14.2, *) else { return }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else { stop(); return }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Horizon Notch level meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr else { stop(); return }
        aggregateID = aggregate

        let rate = Self.sampleRate(of: tap) ?? 48_000
        // Band edges for the four bars: below 200 Hz, 200–1000, 1000–4000, above.
        let edges: [Float] = [200, 1_000, 4_000]
        let newCoefficients = edges.map { 1 - exp(-2 * Float.pi * $0 / Float(rate)) }
        queue.sync {
            coefficients = newCoefficients
            filters = [0, 0, 0]
            silentBuffers = 0
        }

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, _, _, _ in
            self?.analyse(input)
        }
        guard status == noErr, let proc else { stop(); return }
        procID = proc
        if AudioDeviceStart(aggregate, proc) != noErr { stop() }
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        lock.withLock { current = Levels() }
    }

    // MARK: - Analysis

    /// Splits the sound into four bands with simple low-pass filters, takes
    /// each band's loudness, levels it against its own recent peak (so quiet
    /// songs move as much as loud ones) and spots beats as sudden rises
    /// above the running average.
    private func analyse(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)

        var energy: [Float] = [0, 0, 0, 0]
        var total: Float = 0
        var silent = true
        for frame in 0..<frames {
            var x: Float = 0
            for channel in 0..<channels { x += samples[frame * channels + channel] }
            x /= Float(channels)
            if x != 0 { silent = false }
            for i in 0..<3 { filters[i] += coefficients[i] * (x - filters[i]) }
            let low = filters[0], lowMid = filters[1] - filters[0], highMid = filters[2] - filters[1], high = x - filters[2]
            energy[0] += low * low
            energy[1] += lowMid * lowMid
            energy[2] += highMid * highMid
            energy[3] += high * high
            total += x * x
        }
        silentBuffers = silent ? silentBuffers + 1 : 0

        var normalised: [Float] = [0, 0, 0, 0]
        for i in 0..<4 {
            let rms = (energy[i] / Float(frames)).squareRoot()
            peaks[i] = Swift.max(rms, peaks[i] * 0.997, 0.002)
            let value = Swift.min(1, rms / peaks[i])
            // Quick to rise, slower to fall, like a level meter.
            smoothed[i] += (value - smoothed[i]) * (value > smoothed[i] ? 0.6 : 0.15)
            normalised[i] = smoothed[i]
        }
        let rms = (total / Float(frames)).squareRoot()
        levelPeak = Swift.max(rms, levelPeak * 0.997, 0.002)
        let loudness = Swift.min(1, rms / levelPeak)
        level += (loudness - level) * (loudness > level ? 0.6 : 0.15)
        average += (level - average) * 0.03
        let rise = (level - average * 1.25) / Swift.max(average, 0.05)
        beat = Swift.max(beat * 0.86, Swift.min(1, Swift.max(0, rise)))

        let next = Levels(bands: normalised, level: level, beat: beat, hasSignal: silentBuffers < 40)
        lock.withLock { current = next }
    }

    // MARK: - Devices

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func sampleRate(of tap: AudioObjectID) -> Double? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0
        else { return nil }
        return format.mSampleRate
    }
}
