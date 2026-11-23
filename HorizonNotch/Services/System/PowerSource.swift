import Combine
import Foundation
import IOKit
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
        /// Low Power Mode is on (the battery turns yellow, like on iPhone).
        var isLowPower = false
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
        // Low Power Mode is not a power-source change; it has its own signal.
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            let new = PowerSource.read()
            if new != self.state { self.state = new }
        }
    }

    /// Minutes until full when macOS has no estimate yet (right after
    /// plugging in it often reports nothing for minutes): the battery's own
    /// average from the smart battery, else the charge still missing
    /// divided by the current flowing in.
    /// Minutes until full from the current charge rate alone; the last
    /// 20 % go slower (the battery tapers its current there). Steadier than
    /// macOS's estimate, which jumps when Optimised Charging holds at 80 %.
    static func chargeRateMinutesToFull() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        guard let current = (data?["RemainingCapacity"] as? NSNumber)?.intValue ?? number("AppleRawCurrentCapacity"),
              let max = (data?["FullChargeCapacity"] as? NSNumber)?.intValue ?? number("AppleRawMaxCapacity"),
              max > 100, let amperage = number("Amperage") ?? number("InstantAmperage"), amperage > 50 else { return nil }
        let knee = Double(max) * 0.8
        let fast = Swift.max(0, knee - Double(current)) / Double(amperage) * 60
        // Above 80 % the current falls to roughly half on average.
        let slow = (Double(max) - Swift.max(knee, Double(current))) / Double(amperage) * 60 * 2
        let minutes = fast + slow
        return minutes > 0 && minutes < 24 * 60 ? Int(minutes.rounded()) : nil
    }

    static func estimatedMinutesToFull() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        if let average = number("AvgTimeToFull"), average > 0, average < 65535 { return average }
        if let full = number("TimeToFull"), full > 0, full < 65535 { return full }
        // Charge in mAh: newer macOS keeps it only inside "BatteryData"
        // (CurrentCapacity/MaxCapacity there are percentages).
        let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        let current = (data?["RemainingCapacity"] as? NSNumber)?.intValue ?? number("AppleRawCurrentCapacity")
        let max = (data?["FullChargeCapacity"] as? NSNumber)?.intValue ?? number("AppleRawMaxCapacity")
        guard let current, let max, max > 100, let amperage = number("Amperage") ?? number("InstantAmperage"),
              amperage > 50 else { return nil }
        // Charging slows down near full; add a little for the last stretch.
        let minutes = Double(max - current) / Double(amperage) * 60 * 1.15
        return minutes > 0 && minutes < 24 * 60 ? Int(minutes.rounded()) : nil
    }

    private static func read() -> State {
        var state = State()
        state.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
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
