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
        /// What Claude is doing right now, e.g. "Editing router.ts".
        var detail: String?
        /// The end of Claude's last answer, shown when a turn is done.
        var summary: String?
    }

    @Published private(set) var sessions: [Session] = []
    /// Fires when a turn finished, so usage can be refreshed.
    let turnFinished = PassthroughSubject<Void, Never>()

    private var source: DispatchSourceFileSystemObject?
    private var cleanupTimer: Timer?
    private var doneTimers: [String: DispatchWorkItem] = [:]

    init() {
        ClaudeHooks.repairIfNeeded()
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
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // The folder was deleted or moved: start over with a new one.
                source.cancel()
                self.source = nil
                ClaudeHooks.repairIfNeeded()
                try? FileManager.default.createDirectory(at: ClaudeHooks.eventFolder, withIntermediateDirectories: true)
                self.watch()
            }
            self.drain()
        }
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
            session.detail = L("Denkt nach", "Thinking")
            session.summary = nil
        case "PreToolUse":
            let tool = event["tool_name"] as? String
            session.activity = .working(tool: tool)
            session.detail = Self.describe(tool: tool, input: event["tool_input"] as? [String: Any])
            if session.turnStarted == nil { session.turnStarted = Date() }
        case "Notification":
            session.activity = .waiting(event["message"] as? String ?? L("Wartet auf dich", "Waiting for you"))
        case "Stop":
            session.activity = .done
            session.turnStarted = nil
            session.summary = nil
            turnFinished.send()
            if let path = event["transcript_path"] as? String { loadSummary(from: path, for: id) }
            let work = DispatchWorkItem { [weak self] in self?.setActivity(.idle, for: id) }
            doneTimers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
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

    // MARK: - Describing the work

    /// A short line like Pro Notch's: "Editing router.ts", "Run the tests".
    static func describe(tool: String?, input: [String: Any]?) -> String? {
        guard let tool else { return nil }
        let input = input ?? [:]
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit":
            return file.map { L("Bearbeitet ", "Editing ") + $0 } ?? L("Bearbeitet Dateien", "Editing files")
        case "Write":
            return file.map { L("Schreibt ", "Writing ") + $0 } ?? L("Schreibt eine Datei", "Writing a file")
        case "Read":
            return file.map { L("Liest ", "Reading ") + $0 } ?? L("Liest Dateien", "Reading files")
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            let command = (input["command"] as? String ?? "").split(separator: " ").prefix(3).joined(separator: " ")
            return command.isEmpty ? L("Führt einen Befehl aus", "Running a command") : command
        case "Grep", "Glob":
            if let pattern = input["pattern"] as? String { return L("Sucht ", "Searching ") + pattern }
            return L("Sucht im Code", "Searching the code")
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host }
            return host.map { L("Lädt ", "Fetching ") + $0 } ?? L("Lädt eine Seite", "Fetching a page")
        case "WebSearch":
            return (input["query"] as? String).map { L("Sucht im Web: ", "Searching the web: ") + $0 }
        case "Task", "Agent":
            return (input["description"] as? String) ?? L("Startet einen Agenten", "Starting an agent")
        case "TodoWrite":
            return L("Plant die nächsten Schritte", "Planning the next steps")
        default:
            return tool.hasPrefix("mcp__") ? tool.split(separator: "_").last.map(String.init) : tool
        }
    }

    /// The last sentence Claude wrote, read from the end of its transcript
    /// in the background ("All 42 router tests pass now.").
    private func loadSummary(from path: String, for id: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }
            var summary: String?
            for line in text.split(separator: "\n").reversed() {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                guard let last = texts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else { continue }
                summary = Self.lastSentence(of: last)
                break
            }
            guard let summary else { return }
            DispatchQueue.main.async {
                guard let self, let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[index].summary = summary
            }
        }
    }

    private static func lastSentence(of text: String) -> String {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let lines = plain.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.last ?? plain
        var sentences: [String] = []
        line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences.first ?? line
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
