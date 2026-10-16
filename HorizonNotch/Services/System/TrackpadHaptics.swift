import AppKit
import IOKit

/// Trackpad clicks. NSHapticFeedbackManager tops out at a gentle tick, so
/// stronger levels drive the Force Touch actuator directly through the
/// private MultitouchSupport framework (as tools like HapticKey do). If that
/// is unavailable, everything falls back to the public API.
enum TrackpadHaptics {
    private typealias CreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenFn = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let actuate: ActuateFn? = symbol("MTActuatorActuate")

    /// Opened once, on first use.
    private static let actuator: CFTypeRef? = {
        guard let create: CreateFn = symbol("MTActuatorCreateFromDeviceID"),
              let open: OpenFn = symbol("MTActuatorOpen") else { return nil }
        for id in multitouchDeviceIDs() {
            guard let actuator = create(id)?.takeRetainedValue() else { continue }
            if open(actuator) == 0 { return actuator }
        }
        return nil
    }()

    /// IDs of the built-in and Magic trackpads from the IO registry.
    private static func multitouchDeviceIDs() -> [UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var ids: [UInt64] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                ids.append(value.uint64Value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return ids
    }

    /// Number of steps for the strength slider.
    static let levels = 8

    /// Plays one click. Levels 1–3 use the public API (gentle to firm),
    /// 4–7 the actuator's waveforms, 8 two strong pulses back to back.
    static func click(level: Int) {
        switch min(max(level, 1), levels) {
        case 1: NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case 2: NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        case 3: NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        case 4: actuatorOrFallback(3)
        case 5: actuatorOrFallback(4)
        case 6: actuatorOrFallback(5)
        case 7: actuatorOrFallback(6)
        default:
            if pulse(6) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { _ = pulse(6) }
            } else {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    private static func actuatorOrFallback(_ id: Int32) {
        if !pulse(id) { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    }

    @discardableResult
    private static func pulse(_ id: Int32) -> Bool {
        guard let actuate, let actuator else { return false }
        return actuate(actuator, id, 0, 0, 0) == 0
    }
}
