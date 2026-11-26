import Foundation

/// Time-synced lyrics from LRCLIB (lrclib.net, free, no key). Fetched only
/// when the lyrics view is open, cached per track for the session.
final class LyricsService: ObservableObject {
    struct Line: Equatable {
        let time: Double
        let text: String
        /// Start time of each word, if the lyrics carry word stamps
        /// (enhanced LRC, "<mm:ss.xx>word"). Same count as `words`.
        var wordTimes: [Double]? = nil

        var words: [String] { text.split(separator: " ").map(String.init) }
    }

    /// How many words of `lines[index]` have been sung at `position`.
    /// Uses word stamps when present; otherwise follows `sungCharacters`.
    func sungWords(in index: Int, at position: Double) -> Int {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        let words = line.words
        guard !words.isEmpty, position >= line.time else { return 0 }
        if let times = line.wordTimes, times.count == words.count {
            return max(1, times.filter { $0 <= position + 0.05 }.count)
        }
        let sung = sungCharacters(in: index, at: position)
        var before = 0.0
        var count = 0
        for word in words {
            if before <= sung { count += 1 } else { break }
            before += Double(word.count + 1)
        }
        return max(1, count)
    }

    /// How much of `lines[index]` has been sung at `position`, in characters
    /// (fractional, so a word can light up letter by letter). Spaces count.
    /// With word stamps each word fills in its own time. Most lyrics only
    /// time the line: then the line fills evenly over the time it takes to
    /// sing (the song's own pace, at most until the next line); the views
    /// draw a wide soft edge, so no single word looks early or late.
    func sungCharacters(in index: Int, at position: Double) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        let words = line.words
        let total = Double(line.text.count)
        guard !words.isEmpty, position >= line.time else { return 0 }
        let next = lines.indices.contains(index + 1) ? lines[index + 1].time : line.time + 6
        if let times = line.wordTimes, times.count == words.count {
            guard let current = times.lastIndex(where: { $0 <= position + 0.05 }) else { return 0 }
            let before = Double(words.prefix(current).reduce(0) { $0 + $1.count + 1 })
            let length = Double(words[current].count)
            let end = current + 1 < times.count ? times[current + 1] : min(next, times[current] + max(0.3, length * pace * 1.1))
            let fraction = end > times[current] ? (position - times[current]) / (end - times[current]) : 1
            return min(total, before + length * min(max(fraction, 0), 1))
        }
        let span = min(max(0.4, next - line.time) * 0.9, max(1.0, total * pace))
        let progress = (position - line.time) / span
        return min(total, max(0, progress) * total)
    }

    /// Seconds per character this song is sung at, learned from its own
    /// timing: where a line runs straight into the next, the time between
    /// them is about how long it took to sing. Of all lines, the quicker
    /// third shows that pace; lines before a pause are much slower and
    /// don't count.
    private var pace = 0.085

    private static func estimatePace(_ lines: [Line]) -> Double {
        var ratios: [Double] = []
        for index in lines.indices.dropLast() {
            let characters = lines[index].text.count
            let gap = lines[index + 1].time - lines[index].time
            guard characters >= 6, gap > 0.3 else { continue }
            ratios.append(gap / Double(characters))
        }
        guard ratios.count >= 4 else { return 0.085 }
        ratios.sort()
        let quick = ratios[Int(Double(ratios.count - 1) * 0.3)]
        return min(max(quick * 0.92, 0.045), 0.16)
    }

    enum State: Equatable {
        case idle, loading, unavailable, loaded
    }

    @Published private(set) var lines: [Line] = [] {
        didSet { pace = Self.estimatePace(lines) }
    }
    @Published private(set) var state: State = .idle
    private var currentKey = ""
    private var cache: [String: [Line]] = [:]
    private var task: URLSessionDataTask?

    func load(for info: NowPlayingInfo) {
        let key = "\(info.artist)|\(info.title)"
        guard key != currentKey else { return }
        currentKey = key
        task?.cancel()
        if let cached = cache[key] {
            lines = cached
            state = cached.isEmpty ? .unavailable : .loaded
            return
        }
        lines = []
        guard !info.title.isEmpty else {
            state = .unavailable
            return
        }
        state = .loading
        var items = [URLQueryItem(name: "track_name", value: info.title),
                     URLQueryItem(name: "artist_name", value: info.artist)]
        if !info.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: info.album)) }
        if info.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(info.duration.rounded())))) }
        request(path: "get", items: items) { [weak self] object in
            if let synced = (object as? [String: Any])?["syncedLyrics"] as? String {
                self?.finish(key: key, lines: Self.parse(synced))
            } else {
                // No exact match (e.g. different album): search by fields,
                // then free text with the title stripped of "(…)" / "- Edit".
                self?.request(path: "search", items: Array(items.prefix(2))) { object in
                    if let synced = Self.bestMatch(in: object, duration: info.duration) {
                        self?.finish(key: key, lines: Self.parse(synced))
                        return
                    }
                    let query = "\(info.artist) \(Self.baseTitle(info.title))"
                    self?.request(path: "search", items: [URLQueryItem(name: "q", value: query)]) { object in
                        self?.finish(key: key, lines: Self.parse(Self.bestMatch(in: object, duration: info.duration) ?? ""))
                    }
                }
            }
        }
    }

    /// Synced lyrics of the search hit closest in length to the track.
    private static func bestMatch(in object: Any?, duration: Double) -> String? {
        let hits = ((object as? [[String: Any]]) ?? []).filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
        let best = duration > 0
            ? hits.min { abs(($0["duration"] as? Double ?? 0) - duration) < abs(($1["duration"] as? Double ?? 0) - duration) }
            : hits.first
        return best?["syncedLyrics"] as? String
    }

    private static func baseTitle(_ title: String) -> String {
        var result = title
        if let paren = result.firstIndex(where: { $0 == "(" || $0 == "[" }) { result = String(result[..<paren]) }
        if let dash = result.range(of: " - ") { result = String(result[..<dash.lowerBound]) }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Index of the line being sung at `position`, if any.
    func index(at position: Double) -> Int? {
        guard let first = lines.first, position >= first.time - 0.1 else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= position + 0.1 { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func request(path: String, items: [URLQueryItem], completion: @escaping (Any?) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("HorizonNotch/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let object = ok ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) } : nil
            DispatchQueue.main.async { completion(object) }
        }
        task?.resume()
    }

    private func finish(key: String, lines: [Line]) {
        cache[key] = lines
        guard key == currentKey else { return }
        self.lines = lines
        state = lines.isEmpty ? .unavailable : .loaded
    }

    /// Parses LRC: "[mm:ss.xx] text", possibly several stamps per line.
    static func parse(_ lrc: String) -> [Line] {
        var result: [Line] = []
        for raw in lrc.split(separator: "\n") {
            var rest = Substring(raw)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close]
                let parts = stamp.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    stamps.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let (text, wordTimes) = splitWordStamps(String(rest))
            result += stamps.map { Line(time: $0, text: text, wordTimes: wordTimes) }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Removes enhanced-LRC word stamps ("<00:12.34>") from a line and
    /// returns them per word, or nil when the line has none.
    private static func splitWordStamps(_ raw: String) -> (String, [Double]?) {
        guard raw.contains("<") else { return (raw.trimmingCharacters(in: .whitespaces), nil) }
        var words: [String] = []
        var times: [Double] = []
        var pending: Double?
        var rest = Substring(raw)
        while !rest.isEmpty {
            if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
                let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) { pending = m * 60 + s }
                rest = rest[rest.index(after: close)...]
                continue
            }
            let end = rest.firstIndex(of: "<") ?? rest.endIndex
            for word in rest[..<end].split(separator: " ") {
                words.append(String(word))
                times.append(pending ?? times.last ?? 0)
                pending = nil
            }
            rest = rest[end...]
        }
        return (words.joined(separator: " "), words.isEmpty ? nil : times)
    }
}
