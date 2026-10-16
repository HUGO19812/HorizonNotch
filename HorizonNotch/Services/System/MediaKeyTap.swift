import AppKit
import ApplicationServices

/// Intercepts the volume, mute, brightness and keyboard backlight keys with a CGEvent tap so
/// the island can show its own HUD instead of the system overlay.
/// Needs the Accessibility permission; without it nothing is intercepted
/// and macOS keeps showing its own HUD.
final class MediaKeyTap {
    enum Key {
        case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
        case keyboardUp, keyboardDown, keyboardToggle
    }

    /// Return true if the key was handled and must not reach the system.
    var onKey: ((Key, _ fineStep: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        // NX_SYSDEFINED = 14
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow or idle taps; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = nsEvent.data1
        let keyCode = (data & 0xFFFF0000) >> 16
        let keyState = (data & 0xFF00) >> 8
        let isDown = keyState == 0x0A

        let key: Key
        switch keyCode {
        case 0: key = .volumeUp          // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown        // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute              // NX_KEYTYPE_MUTE
        case 2: key = .brightnessUp      // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown    // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 21: key = .keyboardUp       // NX_KEYTYPE_ILLUMINATION_UP
        case 22: key = .keyboardDown     // NX_KEYTYPE_ILLUMINATION_DOWN
        case 23: key = .keyboardToggle   // NX_KEYTYPE_ILLUMINATION_TOGGLE
        default: return Unmanaged.passUnretained(event)
        }
        let flags = nsEvent.modifierFlags
        let fine = flags.contains(.option) && flags.contains(.shift)

        // Decide on key down; swallow the matching key up as well.
        if isDown {
            let handled = onKey?(key, fine) ?? false
            lastHandled[key] = handled
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        return lastHandled[key] == true ? nil : Unmanaged.passUnretained(event)
    }

    private var lastHandled: [Key: Bool] = [:]
}
