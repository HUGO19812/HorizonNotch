import Combine
import Foundation
import IOKit.ps

/// Internal battery state, updated by IOKit power-source notifications.
final class PowerSource: ObservableObject {
    struct State: Equatable {
        var hasBattery = false
        var percent = 100
        var isCharging = false
        var isPluggedIn = false
        /// Minutes until full or empty; nil while macOS is still estimating.
        var minutesRemaining: Int?
    }

    static let shared = PowerSource()

    @Published private(set) var state = State()
    private var runLoopSource: CFRunLoopSource?

    private init() {
        state = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let power = Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue()
            let new = PowerSource.read()
            if new != power.state { power.state = new }
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private static func read() -> State {
        var state = State()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return state }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            state.hasBattery = true
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            state.percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            state.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            state.isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (state.isCharging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            state.minutesRemaining = (minutes ?? -1) > 0 ? minutes : nil
        }
        return state
    }
}
