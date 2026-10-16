import AppKit

/// Private SkyLight (window server) calls to put a window into its own
/// space with an absolute level above the lock screen. This is the only
/// known way for an app window to appear over the macOS lock screen; the
/// functions are loaded at runtime and everything fails soft if they are
/// missing in a future macOS.
enum SkyLight {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnection: MainConnectionFn? = symbol("SLSMainConnectionID")
    private static let spaceCreate: SpaceCreateFn? = symbol("SLSSpaceCreate")
    private static let setLevel: SetLevelFn? = symbol("SLSSpaceSetAbsoluteLevel")
    private static let showSpaces: ShowSpacesFn? = symbol("SLSShowSpaces")
    private static let addWindows: AddWindowsFn? = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces")

    /// Absolute space level of Notification Center while the screen is
    /// locked; one step above the lock screen itself (300).
    private static let lockScreenLevel: Int32 = 400

    private static var space: UInt64?

    static var isAvailable: Bool {
        mainConnection != nil && spaceCreate != nil && setLevel != nil && showSpaces != nil && addWindows != nil
    }

    /// Moves the window into the lock-screen space (created once).
    @discardableResult
    static func moveAboveLockScreen(_ window: NSWindow) -> Bool {
        guard isAvailable, let mainConnection, let spaceCreate, let setLevel, let showSpaces, let addWindows else {
            return false
        }
        let connection = mainConnection()
        if space == nil {
            let created = spaceCreate(connection, 1, nil)
            guard created != 0 else { return false }
            _ = setLevel(connection, created, lockScreenLevel)
            _ = showSpaces(connection, [NSNumber(value: created)] as CFArray)
            space = created
        }
        guard let space else { return false }
        return addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7) == 0
    }
}
