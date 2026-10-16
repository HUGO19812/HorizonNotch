import AppKit
import Combine

/// Keeps the Mac awake – also with the lid closed – until switched off.
///
/// Normal sleep blockers (IOPMAssertion, caffeinate) do not stop clamshell
/// sleep on battery. The only reliable switch is `pmset -a disablesleep 1`,
/// which needs administrator rights: macOS asks for the password when it is
/// turned on or off. The setting persists (also across restarts) until it is
/// switched off again, so the app reads the real state from `pmset -g`.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isOn = false
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    /// Reads the real state from `pmset -g` in the background. Waiting for
    /// the process on the main thread would let SwiftUI re-enter while this
    /// object is still being created.
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            let on = output.split(separator: "\n").contains { line in
                line.contains("SleepDisabled") && line.split(whereSeparator: \.isWhitespace).last == "1"
            }
            DispatchQueue.main.async {
                if on != self?.isOn { self?.isOn = on }
            }
        }
    }

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        let command = "/usr/bin/pmset -a disablesleep \(on ? 1 : 0)"
        var error: NSDictionary?
        NSApp.activate()
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&error)
        // -128: the user cancelled the password dialog.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String
        } else {
            lastError = nil
        }
        refresh()
    }
}
