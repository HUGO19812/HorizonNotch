import Foundation
import ObjectiveC

/// Keyboard backlight through the private KeyboardBrightnessClient class
/// of CoreBrightness (loaded at runtime; there is no public API).
enum KeyboardBacklight {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    private static let keyboardID: UInt64? = {
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let client, client.responds(to: selector),
              let ids = client.perform(selector)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }()

    private static func implementation<T>(_ name: String, as type: T.Type) -> T? {
        let selector = NSSelectorFromString(name)
        guard let client, client.responds(to: selector) else { return nil }
        return unsafeBitCast(client.method(for: selector), to: type)
    }

    static var isAvailable: Bool { keyboardID != nil }

    static var brightness: Float? {
        guard let client, let id = keyboardID,
              let get = implementation("brightnessForKeyboard:", as: GetFn.self) else { return nil }
        return get(client, NSSelectorFromString("brightnessForKeyboard:"), id)
    }

    static func setBrightness(_ value: Float) {
        guard let client, let id = keyboardID,
              let set = implementation("setBrightness:forKeyboard:", as: SetFn.self) else { return }
        // A manual change switches off automatic adjustment, like the system does.
        if let auto = implementation("enableAutoBrightness:forKeyboard:", as: SetBoolFn.self) {
            auto(client, NSSelectorFromString("enableAutoBrightness:forKeyboard:"), false, id)
        }
        _ = set(client, NSSelectorFromString("setBrightness:forKeyboard:"), min(max(value, 0), 1), id)
    }

    private typealias SetBoolFn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Void
}
