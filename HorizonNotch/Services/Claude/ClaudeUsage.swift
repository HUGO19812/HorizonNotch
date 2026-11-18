import Foundation

/// Claude Code token usage from its local logs (~/.claude/projects/**/*.jsonl),
/// with an API-price estimate from OpenRouter's public model list (as Atoll
/// does). On a subscription the price is only what the same usage would
/// cost through the API.
final class ClaudeUsage: ObservableObject {
    struct Totals: Equatable {
        var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        var cost: Double = 0
        var priced = true
        var tokens: Int { input + output + cacheWrite + cacheRead }
    }

    @Published private(set) var today = Totals()
    /// Current 5-hour session window (how Claude plans count usage).
    @Published private(set) var block = Totals()
    @Published private(set) var blockEnds: Date?
    @Published private(set) var topModel: String?

    /// One plan limit as Claude Code reports it.
    struct Limit: Equatable {
        /// 0…100.
        let percent: Double
        let resets: Date
    }
    /// The 5-hour and the weekly limit of a Pro/Max plan, from Claude
    /// Code's status line (see ClaudeHooks); nil until it reported them.
    @Published private(set) var fiveHour: Limit?
    @Published private(set) var weekly: Limit?
    /// Why no plan usage arrived, if it did not (shown on the ring).
    @Published private(set) var planProblem: String?

    private var lastFetch: Date?

    /// Asks Claude for the plan usage directly – the same request Claude
    /// Code makes for /usage, with the login it keeps in the keychain – so
    /// it shows even when no session runs. At most once a minute; nothing
    /// is stored, and it only goes to Anthropic.
    private func fetchPlanUsage() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 60 { return }
        lastFetch = Date()
        queue.async { [weak self] in
            let login = Self.claudeLogin()
            guard case .success(let token) = login,
                  let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
                if case .failure(let problem) = login { self?.report(problem.text) }
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            URLSession.shared.dataTask(with: request) { data, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    NSLog("[HorizonNotch] plan usage: HTTP %ld %@", code, error?.localizedDescription ?? "")
                    switch code {
                    case 401, 403:
                        self?.report(L("Claude-Login abgelaufen – einmal Claude Code benutzen, dann klappt es wieder.",
                                       "Claude login expired – use Claude Code once and it works again."))
                    case 0:
                        self?.report(L("Keine Verbindung zu Claude.", "No connection to Claude."))
                    default:
                        self?.report(L("Claude antwortet mit Fehler \(code).", "Claude answered with error \(code)."))
                    }
                    return
                }
                func limit(_ key: String) -> Limit? {
                    guard let entry = json[key] as? [String: Any],
                          let percent = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
                    let reset = Self.date(entry["resets_at"]) ?? Date().addingTimeInterval(3600)
                    return Limit(percent: percent, resets: reset)
                }
                let five = limit("five_hour"), week = limit("seven_day")
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.planProblem = five == nil && week == nil
                        ? L("Dein Abo meldet keine Limits.", "Your plan reports no limits.") : nil
                    if let five, five != self.fiveHour { self.fiveHour = five }
                    if let week, week != self.weekly { self.weekly = week }
                }
            }.resume()
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct Problem: Error { let text: String }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.planProblem = text }
    }

    /// Claude Code's login from the keychain (read through macOS'
    /// `security` tool, as Claude Code itself does).
    private static func claudeLogin() -> Result<String, Problem> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return .failure(Problem(text: L("Schlüsselbund nicht lesbar.", "Keychain not readable.")))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            NSLog("[HorizonNotch] plan usage: security exit %d", process.terminationStatus)
            return .failure(Problem(text: process.terminationStatus == 44
                ? L("Kein Claude-Code-Login im Schlüsselbund.", "No Claude Code login in the keychain.")
                : L("Zugriff auf den Claude-Login nicht erlaubt (Schlüsselbund-Abfrage).",
                    "Access to the Claude login was not allowed (keychain prompt).")))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["claudeAiOauth"] as? [String: Any],
              let token = login["accessToken"] as? String else {
            return .failure(Problem(text: L("Claude-Login hat ein unbekanntes Format.", "Claude login has an unknown format.")))
        }
        return .success(token)
    }

    private func readLimits() {
        guard let data = try? Data(contentsOf: ClaudeHooks.statusURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return }
        func limit(_ key: String) -> Limit? {
            guard let entry = limits[key] as? [String: Any],
                  let percent = (entry["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (entry["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            let date = Date(timeIntervalSince1970: reset)
            // A window that has started over counts as unused.
            return date > Date() ? Limit(percent: percent, resets: date) : nil
        }
        // Only fresh windows; the direct request fills in the rest.
        if let five = limit("five_hour"), five != fiveHour { fiveHour = five }
        if let week = limit("seven_day"), week != weekly { weekly = week }
    }

    private struct Entry {
        let time: Date
        let model: String
        let input, output, cacheWrite, cacheRead: Int
    }

    private struct Price {
        let input, output, cacheWrite, cacheRead: Double
    }

    private let queue = DispatchQueue(label: "horizon.claude.usage", qos: .utility)
    private var fileOffsets: [String: UInt64] = [:]
    private var entries: [Entry] = []
    private var seen = Set<String>()
    private var prices: [String: Price] = [:]
    private var pricesLoaded: Date?
    private var refreshing = false

    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    /// Reads what was appended to the logs since last time. Cheap to call
    /// often; callers do so when the page opens and after each turn.
    func refresh() {
        readLimits()
        fetchPlanUsage()
        guard !refreshing else { return }
        refreshing = true
        queue.async { [weak self] in
            guard let self else { return }
            self.loadPricesIfNeeded()
            self.scan()
            let summary = self.summarize()
            DispatchQueue.main.async {
                self.refreshing = false
                if summary.0 != self.today { self.today = summary.0 }
                if summary.1 != self.block { self.block = summary.1 }
                self.blockEnds = summary.2
                self.topModel = summary.3
            }
        }
    }

    // MARK: - Logs

    private func scan() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-36 * 3600)
        guard let enumerator = manager.enumerator(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > cutoff else { continue }
            read(url)
        }
        entries.removeAll { $0.time < cutoff }
    }

    private func read(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let offset = fileOffsets[url.path] ?? 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only complete lines; a half-written last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        fileOffsets[url.path] = offset + UInt64(lastNewline + 1)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let marker = Data("\"usage\"".utf8)
        for line in data[..<lastNewline].split(separator: 0x0A) where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String, let time = formatter.date(from: stamp) else { continue }
            // Streaming writes the same message several times; count it once.
            let key = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
            guard seen.insert(key).inserted else { continue }
            entries.append(Entry(time: time, model: message["model"] as? String ?? "?",
                                 input: usage["input_tokens"] as? Int ?? 0,
                                 output: usage["output_tokens"] as? Int ?? 0,
                                 cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                                 cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0))
        }
    }

    // MARK: - Totals

    private func summarize() -> (Totals, Totals, Date?, String?) {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let sorted = entries.sorted { $0.time < $1.time }

        var today = Totals()
        var perModel: [String: Int] = [:]
        for entry in sorted where entry.time >= startOfDay {
            add(entry, to: &today)
            perModel[entry.model, default: 0] += entry.input + entry.output + entry.cacheWrite + entry.cacheRead
        }

        // 5-hour windows: a window starts at the full hour of the first
        // message after the previous window ended.
        var blockStart: Date?
        var block = Totals()
        for entry in sorted {
            if let start = blockStart, entry.time < start.addingTimeInterval(5 * 3600) {
                add(entry, to: &block)
            } else {
                blockStart = Calendar.current.dateInterval(of: .hour, for: entry.time)?.start ?? entry.time
                block = Totals()
                add(entry, to: &block)
            }
        }
        let ends = blockStart.map { $0.addingTimeInterval(5 * 3600) }
        if let ends, ends < now { return (today, Totals(), nil, perModel.max { $0.value < $1.value }?.key) }
        return (today, block, ends, perModel.max { $0.value < $1.value }?.key)
    }

    private func add(_ entry: Entry, to totals: inout Totals) {
        totals.input += entry.input
        totals.output += entry.output
        totals.cacheWrite += entry.cacheWrite
        totals.cacheRead += entry.cacheRead
        if let price = prices[Self.normalize(entry.model)] {
            totals.cost += Double(entry.input) * price.input + Double(entry.output) * price.output
                + Double(entry.cacheWrite) * price.cacheWrite + Double(entry.cacheRead) * price.cacheRead
        } else {
            totals.priced = false
        }
    }

    // MARK: - Prices

    /// "claude-opus-4-5-20251101" and "anthropic/claude-opus-4.5" → "claude-opus-4-5".
    private static func normalize(_ model: String) -> String {
        var name = model.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = name.replacingOccurrences(of: ".", with: "-")
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name
    }

    private func loadPricesIfNeeded() {
        if let loaded = pricesLoaded, Date().timeIntervalSince(loaded) < 12 * 3600 { return }
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Price] = [:]
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["data"] as? [[String: Any]] else { return }
            for model in models {
                // Variants such as ":thinking" share the base model's price.
                guard let id = model["id"] as? String, id.hasPrefix("anthropic/"), !id.contains(":"),
                      let pricing = model["pricing"] as? [String: Any] else { continue }
                func value(_ key: String) -> Double { Double(pricing[key] as? String ?? "") ?? 0 }
                let input = value("prompt")
                result[Self.normalize(id)] = Price(input: input, output: value("completion"),
                                                   cacheWrite: value("input_cache_write").nonZero ?? input * 1.25,
                                                   cacheRead: value("input_cache_read").nonZero ?? input * 0.1)
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        if !result.isEmpty {
            prices = result
            pricesLoaded = Date()
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
