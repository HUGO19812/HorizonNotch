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

    /// How many words of `lines[index]` are lit at `position`: the whole
    /// line from its start. Lines light up as a whole – timing each word
    /// put some early and others late.
    func sungWords(in index: Int, at position: Double) -> Int {
        guard lines.indices.contains(index), position >= lines[index].time - Self.lead else { return 0 }
        return lines[index].words.count
    }

    /// How much of `lines[index]` is lit at `position`, in characters: all
    /// of it from the line's start (see `sungWords`).
    func sungCharacters(in index: Int, at position: Double) -> Double {
        guard lines.indices.contains(index), position >= lines[index].time - Self.lead else { return 0 }
        return Double(lines[index].text.count)
    }

    /// A line counts from a tenth of a second before its stamp: by the time
    /// it is drawn and faded in, the first word is being sung.
    static let lead = 0.1

    enum State: Equatable {
        case idle, loading, unavailable, loaded
    }

    @Published private(set) var lines: [Line] = []
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
        guard let first = lines.first, position >= first.time - Self.lead else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= position + Self.lead { low = mid } else { high = mid - 1 }
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
