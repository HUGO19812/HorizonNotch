import Combine
import Foundation

/// Live state of Claude Code sessions, fed by the hook events that
/// ClaudeHooks' script drops into a folder. The folder is watched with a
/// kqueue source – no polling.
final class ClaudeCodeMonitor: ObservableObject {
    enum Activity: Equatable {
        /// Working on a prompt; the tool currently used, if any.
        case working(tool: String?)
        /// Asking for permission or input.
        case waiting(String)
        /// Just finished; shown briefly.
        case done
        case idle
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var project: String
        var activity: Activity
        var turnStarted: Date?
        var updated: Date
    }

    @Published private(set) var sessions: [Session] = []
    /// Fires when a turn finished, so usage can be refreshed.
    let turnFinished = PassthroughSubject<Void, Never>()

    private var source: DispatchSourceFileSystemObject?
    private var cleanupTimer: Timer?
    private var doneTimers: [String: DispatchWorkItem] = [:]

    init() {
        try? FileManager.default.createDirectory(at: ClaudeHooks.eventFolder, withIntermediateDirectories: true)
        watch()
        drain()
    }

    /// Sessions worth showing next to the notch, most urgent first.
    var visible: [Session] {
        sessions.filter { $0.activity != .idle }.sorted { rank($0) < rank($1) }
    }

    private func rank(_ session: Session) -> Int {
        switch session.activity {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }

    // MARK: - Events

    private func watch() {
        let descriptor = open(ClaudeHooks.eventFolder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Reads and deletes all event files, oldest first.
    private func drain() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: ClaudeHooks.eventFolder, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }
        for file in files {
            defer { try? manager.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            apply(event)
        }
    }

    private func apply(_ event: [String: Any]) {
        guard let id = event["session_id"] as? String, let name = event["hook_event_name"] as? String else { return }
        let cwd = event["cwd"] as? String ?? ""
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        var session = sessions.first { $0.id == id } ?? Session(id: id, project: project, activity: .idle, updated: Date())
        if !project.isEmpty { session.project = project }
        session.updated = Date()
        doneTimers[id]?.cancel()

        switch name {
        case "SessionEnd":
            sessions.removeAll { $0.id == id }
            return
        case "UserPromptSubmit":
            session.activity = .working(tool: nil)
            session.turnStarted = Date()
        case "PreToolUse":
            session.activity = .working(tool: event["tool_name"] as? String)
            if session.turnStarted == nil { session.turnStarted = Date() }
        case "Notification":
            session.activity = .waiting(event["message"] as? String ?? L("Wartet auf dich", "Waiting for you"))
        case "Stop":
            session.activity = .done
            session.turnStarted = nil
            turnFinished.send()
            let work = DispatchWorkItem { [weak self] in self?.setActivity(.idle, for: id) }
            doneTimers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        default:
            break
        }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        scheduleCleanup()
    }

    private func setActivity(_ activity: Activity, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].activity = activity
    }

    /// Sessions that went quiet (e.g. Claude was killed) are dropped after
    /// a while. The timer only runs while sessions exist.
    private func scheduleCleanup() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] timer in
            guard let self else { return }
            let now = Date()
            for index in self.sessions.indices {
                if case .working = self.sessions[index].activity,
                   now.timeIntervalSince(self.sessions[index].updated) > 15 * 60 {
                    self.sessions[index].activity = .idle
                }
            }
            self.sessions.removeAll { now.timeIntervalSince($0.updated) > 6 * 3600 }
            if self.sessions.isEmpty {
                timer.invalidate()
                self.cleanupTimer = nil
            }
        }
        cleanupTimer?.tolerance = 20
    }
}
