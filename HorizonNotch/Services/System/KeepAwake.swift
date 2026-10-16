import AppKit
import Combine

/// Keeps the Mac awake – also with the lid closed – until switched off.
///
/// Normal sleep blockers (IOPMAssertion, caffeinate) do not stop clamshell
/// sleep on battery. The only reliable switch is `pmset -a disablesleep 1`,
/// which needs root. So that macOS does not ask for the password on every
/// switch, the first switch also installs a sudoers rule that allows exactly
/// these two commands without a password (like Amphetamine Enhancer's
/// one-time setup). After that, switching runs `sudo -n pmset …`.
/// The setting persists (also across restarts) until it is switched off
/// again, so the app reads the real state from `pmset -g`.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isOn = false
    @Published private(set) var lastError: String?
    /// The password-free rule is installed.
    @Published private(set) var isSetUp = false

    private static let sudoersPath = "/etc/sudoers.d/horizonnotch"
    private static let pmset = "/usr/bin/pmset"

    private init() {
        isSetUp = FileManager.default.fileExists(atPath: Self.sudoersPath)
        refresh()
    }

    /// Reads the real state from `pmset -g` in the background. Waiting for
    /// the process on the main thread would let SwiftUI re-enter while this
    /// object is still being created.
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (_, output) = Self.run(Self.pmset, ["-g"])
            let on = output.split(separator: "\n").contains { line in
                line.contains("SleepDisabled") && line.split(whereSeparator: \.isWhitespace).last == "1"
            }
            let setUp = FileManager.default.fileExists(atPath: Self.sudoersPath)
            DispatchQueue.main.async {
                if on != self?.isOn { self?.isOn = on }
                if setUp != self?.isSetUp { self?.isSetUp = setUp }
            }
        }
    }

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        let value = on ? "1" : "0"
        // Show the new state right away; refresh() corrects it on failure.
        isOn = on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, _) = Self.run("/usr/bin/sudo", ["-n", Self.pmset, "-a", "disablesleep", value])
            DispatchQueue.main.async {
                if status == 0 {
                    self?.lastError = nil
                    self?.refresh()
                } else {
                    self?.setUpAndSet(value)
                }
            }
        }
    }

    /// Asks for the password once: switches and installs the sudoers rule.
    private func setUpAndSet(_ value: String) {
        let user = NSUserName()
        guard user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            runWithPassword("\(Self.pmset) -a disablesleep \(value)")
            return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 0, \(Self.pmset) -a disablesleep 1"
        let temp = "/tmp/horizonnotch.sudoers.$$"
        // The rule is checked with visudo before it is put in place, so a
        // broken file can never lock sudo.
        let script = [
            "\(Self.pmset) -a disablesleep \(value)",
            "printf '%s\\n' '\(rule)' > \(temp)",
            "/usr/sbin/chown root:wheel \(temp)",
            "/bin/chmod 0440 \(temp)",
            "if /usr/sbin/visudo -cf \(temp) >/dev/null; then /bin/mv \(temp) \(Self.sudoersPath); else /bin/rm -f \(temp); fi",
        ].joined(separator: "; ")
        runWithPassword(script)
    }

    private func runWithPassword(_ command: String) {
        var error: NSDictionary?
        NSApp.activate()
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        // -128: the user cancelled the password dialog.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            lastError = error[NSAppleScript.errorMessage] as? String
        } else {
            lastError = nil
        }
        refresh()
    }

    /// Removes the password-free rule again (asks for the password).
    func removeSetup() {
        runWithPassword("/bin/rm -f \(Self.sudoersPath)")
    }

    private static func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
