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
