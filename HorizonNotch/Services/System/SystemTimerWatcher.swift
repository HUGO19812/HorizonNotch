import AppKit

/// Timers started in macOS's Clock app (or with Siri). mobiletimerd keeps
/// them in its preferences ("MTTimers"): a running timer's fire time is a
/// date, a paused one a remaining interval, a stopped one has state 1.
/// mobiletimerd can't be asked directly (its service only answers Apple's
/// apps), and its file is written late. The preferences daemon has the new
/// values at once, though: they're read every 1.5 s while the Clock app runs
/// or a timer exists, otherwise only when the preferences folder changes.
final class SystemTimerWatcher {
    enum Status: Equatable {
        case running(end: Date, length: TimeInterval)
        case paused(remaining: TimeInterval, length: TimeInterval)
    }

    var onChange: ((Status?) -> Void)?

    private let domain = "com.apple.mobiletimerd" as CFString
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var last: Status?
    private var checkScheduled = false
    private var observers: [NSObjectProtocol] = []
    private static let clockApp = "com.apple.clock"

    private var clockRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.clockApp).isEmpty
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == Self.clockApp { self?.check() }
            })
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences").path
        let fd = open(folder, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleCheck() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        check()
    }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.checkScheduled = false
            self?.check()
        }
    }

    private func check() {
        let status = read()
        // Keep looking while one exists: pausing and stopping only reach
        // the file after a while.
        let watch = status != nil || clockRunning
        if watch, poll == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
            timer.tolerance = 0.3
            poll = timer
        } else if !watch {
            poll?.invalidate()
            poll = nil
        }
        guard status != last else { return }
        last = status
        onChange?(status)
    }

    private func read() -> Status? {
        CFPreferencesAppSynchronize(domain)
        guard let root = CFPreferencesCopyAppValue("MTTimers" as CFString, domain) as? [String: Any],
              let timers = root["MTTimers"] as? [[String: Any]] else { return nil }
        var best: Status?
        for entry in timers {
            guard let timer = entry["$MTTimer"] as? [String: Any] else { continue }
            let state = (timer["MTTimerState"] as? NSNumber)?.intValue ?? 1
            guard state != 1 else { continue }
            let length = (timer["MTTimerDuration"] as? NSNumber)?.doubleValue ?? 0
            let fire = timer["MTTimerFireTime"]
            if let end = Self.firstDate(in: fire), end > Date() {
                // The soonest running one wins.
                if case .running(let other, _)? = best, other < end { continue }
                best = .running(end: end, length: max(length, end.timeIntervalSinceNow))
            } else if best == nil, let remaining = Self.firstNumber(in: fire), remaining > 0 {
                best = .paused(remaining: remaining, length: max(length, remaining))
            }
        }
        return best
    }

    private static func firstDate(in value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values { if let date = firstDate(in: child) { return date } }
        }
        return nil
    }

    private static func firstNumber(in value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values { if let number = firstNumber(in: child) { return number } }
        }
        return nil
    }
}
