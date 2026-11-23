import AppKit
import SwiftUI

/// Cover and lyrics on the lock screen in the look of Spicetify's Spicy
/// Lyrics, everything below the clock: on the left the cover as a card
/// (Apple Music's moving cover when the album has one), the progress, title
/// and artist under it; on the right the lyrics, big and bold – the line
/// being sung bright, its words filling letter by letter with a soft glow,
/// the others translucent and softly blurred. Behind it all a slowly moving
/// wash of the cover's colours that swells with the music.
struct SpicyLockScreen: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    let info: NowPlayingInfo
    let size: CGSize
    /// A sharper copy of the cover, if one was found.
    var artwork: NSImage?
    /// Back to the large cover without lyrics.
    let onClose: () -> Void

    @StateObject private var motion = MotionArtwork()
    @State private var motionReady = false
    @State private var palette: [Color] = []
    @State private var controlsVisible = true
    @State private var lastMouse = NSEvent.mouseLocation
    @State private var hideWork: DispatchWorkItem?
    /// The panel above the lock screen gets no mouse-moved events, so the
    /// pointer is looked at a few times a second instead.
    private let mouseTick = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Everything starts below the clock; behind the clock is only the
    /// background.
    private var top: CGFloat { size.height * 0.27 }
    private var lineSize: CGFloat { max(28, size.height * 0.045) }
    private var coverSide: CGFloat { min(size.height * 0.44, size.width * 0.27) }
    private var lyricsLeft: CGFloat { size.width * 0.5 }
    private var lyricsWidth: CGFloat { size.width - lyricsLeft - size.width * 0.04 }
    private var image: NSImage? { artwork ?? nowPlaying.artwork }

    var body: some View {
        let current = nowPlaying.info ?? info
        ZStack(alignment: .topLeading) {
            ReactiveBackdrop(palette: palette, playing: current.isPlaying, size: size)
            SpicyLyrics(lyrics: lyrics, info: current, fontSize: lineSize) { nowPlaying.seek(to: $0) }
                .frame(width: lyricsWidth, height: size.height - top + size.height * 0.02)
                .position(x: lyricsLeft + lyricsWidth / 2, y: (top - size.height * 0.02 + size.height) / 2)
            leftColumn(current)
                .frame(width: coverSide + 40)
                .position(x: size.width * 0.25, y: top + (size.height - top) * 0.47)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            lyrics.load(for: info)
            updatePalette()
            scheduleHide()
        }
        .onChange(of: info.title + info.artist) { _, _ in lyrics.load(for: info) }
        .onChange(of: image) { _, _ in updatePalette() }
        .task(id: current.artist + "|" + current.title) {
            motionReady = false
            await motion.load(for: current)
        }
        .onReceive(mouseTick) { _ in
            let mouse = NSEvent.mouseLocation
            guard mouse != lastMouse else { return }
            lastMouse = mouse
            if !controlsVisible { withAnimation(.easeOut(duration: 0.25)) { controlsVisible = true } }
            scheduleHide()
        }
    }

    private func updatePalette() {
        guard let image else { palette = []; return }
        let colors = ColorExtractor.palette(of: image).map { Color(nsColor: $0) }
        withAnimation(.easeInOut(duration: 1.2)) { palette = colors }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.6)) { controlsVisible = false } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - Cover, progress, title (left)

    private func leftColumn(_ current: NowPlayingInfo) -> some View {
        VStack(spacing: 0) {
            ZStack {
                CoverArt(image: image, cornerRadius: 14)
                if let url = motion.url {
                    LoopingVideo(url: url, ready: $motionReady)
                        .opacity(motionReady ? 1 : 0)
                        .animation(.easeInOut(duration: 0.8), value: motionReady)
                }
            }
            .frame(width: coverSide, height: coverSide)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            LockProgress(service: nowPlaying, info: current)
                .frame(width: coverSide)
                .padding(.top, 22)
            Text(current.title)
                .font(.system(size: 26, weight: .heavy))
                .lineLimit(1)
                .padding(.top, 14)
            Text(current.artist.isEmpty ? (current.appName ?? "") : current.artist)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.top, 2)
            HStack(spacing: 4) {
                if nowPlaying.canLike {
                    LockButton(symbol: nowPlaying.liked ? "heart.fill" : "heart", size: 15) { nowPlaying.toggleLike() }
                        .foregroundStyle(nowPlaying.liked ? Color(red: 0.98, green: 0.33, blue: 0.47) : .white)
                        .symbolEffect(.bounce, value: nowPlaying.likePulse)
                }
                LockButton(symbol: "backward.fill", size: 17) { nowPlaying.send(.previous) }
                LockButton(symbol: current.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                    nowPlaying.send(.togglePlayPause)
                }
                LockButton(symbol: "forward.fill", size: 17) { nowPlaying.send(.next) }
                LockButton(symbol: "quote.bubble.fill", size: 14, action: onClose)
                    .help(L("Songtext ausblenden", "Hide lyrics"))
            }
            .padding(.top, 10)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

// MARK: - Background

/// Soft blobs in the cover's colours drifting slowly over a deeper base;
/// they swell a little on each beat while music plays (when the audio
/// level is available). Radial gradients, no blur, so it stays light.
private struct ReactiveBackdrop: View {
    let palette: [Color]
    let playing: Bool
    let size: CGSize

    var body: some View {
        let colors = palette.isEmpty ? [Color(white: 0.25), Color(white: 0.15)] : palette
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let levels = AudioLevelMeter.shared.levels
            let beat = playing && levels.hasSignal ? Double(levels.beat) : 0
            ZStack {
                colors[0].brightness(-0.25)
                ForEach(0..<5, id: \.self) { i in
                    let color = colors[i % colors.count]
                    let speed = playing ? 1.0 : 0.35
                    let x = 0.5 + 0.42 * sin(t * 0.045 * speed * Double(i + 1) + Double(i) * 1.9)
                    let y = 0.5 + 0.42 * cos(t * 0.037 * speed * Double(i + 2) + Double(i) * 2.7)
                    let radius = max(size.width, size.height) * (0.42 + 0.06 * sin(t * 0.09 + Double(i))) * (1 + 0.1 * beat)
                    RadialGradient(colors: [color.opacity(0.9), color.opacity(0)],
                                   center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: radius)
                }
                Color.black.opacity(0.12)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { AudioLevelMeter.shared.acquire() }
        .onDisappear { AudioLevelMeter.shared.release() }
        .allowsHitTesting(false)
    }
}

// MARK: - Lyrics

private struct SpicyLyrics: View {
    @ObservedObject var lyrics: LyricsService
    let info: NowPlayingInfo
    let fontSize: CGFloat
    let onSeek: (Double) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            switch lyrics.state {
            case .loaded:
                // Which line is current changes a few times a second at most;
                // the letters of that line animate on their own (SpicyActiveLine).
                TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.1 : 3600)) { context in
                    let position = info.elapsed(at: context.date) + settings.lyricsOffset
                    SpicyScroller(lyrics: lyrics, current: lyrics.index(at: position), info: info,
                                  fontSize: fontSize, onSeek: onSeek)
                }
            case .loading:
                status(L("Songtext wird geladen …", "Loading lyrics …"))
            case .unavailable, .idle:
                status(L("Kein synchronisierter Songtext", "No synced lyrics"))
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct SpicyScroller: View {
    @ObservedObject var lyrics: LyricsService
    let current: Int?
    let info: NowPlayingInfo
    let fontSize: CGFloat
    let onSeek: (Double) -> Void
    @State private var hovered: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: fontSize * 0.3) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        row(index, line)
                            .id(index)
                    }
                }
                .padding(.vertical, fontSize * 8)
            }
            .scrollDisabled(true)
            // Soft edges, wider at the top where the clock is.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { proxy.scrollTo(current ?? 0, anchor: UnitPoint(x: 0, y: 0.42)) }
            .onChange(of: current) { _, index in
                withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
                    proxy.scrollTo(index ?? 0, anchor: UnitPoint(x: 0, y: 0.42))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ line: LyricsService.Line) -> some View {
        let isCurrent = index == current
        let distance = current.map { abs(index - $0) } ?? 3
        let isHovered = hovered == index && !isCurrent
        let isPast = current.map { index < $0 } ?? false
        Group {
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                InterludeDots(size: fontSize, active: isCurrent && info.isPlaying)
            } else if isCurrent {
                SpicyActiveLine(lyrics: lyrics, index: index, info: info, fontSize: fontSize)
            } else {
                SpicyStillLine(line: line, fontSize: fontSize, opacity: isHovered ? 0.85 : (isPast ? 0.38 : 0.45))
            }
        }
        .blur(radius: isCurrent || isHovered ? 0 : min(3, Double(max(distance - 1, 0)) * 0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, fontSize * 0.35)
        .padding(.vertical, fontSize * 0.15)
        // Hovering a line lays a light pane under it.
        .background(RoundedRectangle(cornerRadius: fontSize * 0.35, style: .continuous)
            .fill(Color.white.opacity(isHovered ? 0.1 : 0)))
        .padding(.horizontal, -fontSize * 0.35)
        .contentShape(Rectangle())
        // Click a line to jump there.
        .onTapGesture { onSeek(line.time) }
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .animation(.easeInOut(duration: 0.45), value: isCurrent)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// The words of a line, split into the sung part and the background vocals
/// in brackets, each with its place among all the line's characters.
private struct LyricWords {
    struct Word: Identifiable {
        let id: Int
        let text: String
        /// Characters before this word in the whole line (spaces count).
        let offset: Double
        let length: Double
    }

    var main: [Word] = []
    var background: [Word] = []

    init(_ line: LyricsService.Line) {
        var offset = 0.0
        var inBrackets = false
        for (index, raw) in line.words.enumerated() {
            if raw.hasPrefix("(") { inBrackets = true }
            let shown = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let word = Word(id: index, text: shown, offset: offset, length: Double(raw.count))
            if !shown.isEmpty {
                if inBrackets { background.append(word) } else { main.append(word) }
            }
            if raw.hasSuffix(")") { inBrackets = false }
            offset += Double(raw.count + 1)
        }
    }

    func fill(_ word: Word, sung: Double) -> Double {
        guard word.length > 0 else { return 0 }
        return min(max((sung - word.offset) / word.length, 0), 1)
    }
}

/// The line being sung: every word fills with white letter by letter, the
/// word being sung glows and rises a little.
private struct SpicyActiveLine: View {
    @ObservedObject var lyrics: LyricsService
    let index: Int
    let info: NowPlayingInfo
    let fontSize: CGFloat

    var body: some View {
        let words = LyricWords(lyrics.lines[index])
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !info.isPlaying)) { context in
            let position = info.elapsed(at: context.date) + AppSettings.shared.lyricsOffset
            let sung = lyrics.lines.indices.contains(index) ? lyrics.sungCharacters(in: index, at: position) : 0
            VStack(alignment: .leading, spacing: fontSize * 0.1) {
                WordFlow(spacing: fontSize * 0.27, lineSpacing: fontSize * 0.06) {
                    ForEach(words.main) { word in
                        SpicyWord(text: word.text, fill: words.fill(word, sung: sung), size: fontSize)
                    }
                }
                if !words.background.isEmpty {
                    WordFlow(spacing: fontSize * 0.2, lineSpacing: 0) {
                        ForEach(words.background) { word in
                            SpicyWord(text: word.text, fill: words.fill(word, sung: sung), size: fontSize * 0.55)
                        }
                    }
                }
            }
        }
    }
}

/// One word: dim underneath, bright on top up to how far it is sung, with a
/// soft edge; glowing while it is being sung.
private struct SpicyWord: View {
    let text: String
    /// 0 = not yet, 1 = sung.
    let fill: Double
    let size: CGFloat

    var body: some View {
        let label = Text(text).font(.system(size: size, weight: .bold))
        // Strongest in the middle of the word, gone once it is sung.
        let glow = fill > 0 && fill < 1 ? sin(fill * .pi) : 0
        let soft = 0.25
        label
            .foregroundStyle(.white.opacity(0.3))
            .overlay(alignment: .leading) {
                label
                    .foregroundStyle(.white)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: min(max(fill * (1 + soft) - soft, 0), 1)),
                                                 .init(color: .clear, location: min(max(fill * (1 + soft), 0.0001), 1))],
                                         startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .white.opacity(0.75 * glow), radius: size * 0.28)
            }
            .offset(y: -size * 0.045 * min(fill * 1.6, 1))
    }
}

/// A line that isn't being sung: plain, dim, background vocals small below.
private struct SpicyStillLine: View {
    let line: LyricsService.Line
    let fontSize: CGFloat
    let opacity: Double

    var body: some View {
        let words = LyricWords(line)
        VStack(alignment: .leading, spacing: fontSize * 0.1) {
            if !words.main.isEmpty {
                Text(words.main.map(\.text).joined(separator: " "))
                    .font(.system(size: fontSize, weight: .bold))
            }
            if !words.background.isEmpty {
                Text(words.background.map(\.text).joined(separator: " "))
                    .font(.system(size: fontSize * 0.55, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(opacity))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Three dots breathing one after another during an instrumental part.
private struct InterludeDots: View {
    let size: CGFloat
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.22) {
                ForEach(0..<3, id: \.self) { dot in
                    let wave = active ? (sin(t * 3 - Double(dot) * 0.8) + 1) / 2 : 0
                    Circle()
                        .fill(Color.white.opacity(active ? 0.7 + 0.3 * wave : 0.45))
                        .frame(width: size * 0.42, height: size * 0.42)
                        .scaleEffect(active ? 0.85 + 0.2 * wave : 0.85)
                        .shadow(color: .white.opacity(active ? 0.6 * wave : 0), radius: size * 0.25)
                }
            }
            .frame(height: size)
        }
    }
}

/// Lays words out left to right and wraps them like text.
private struct WordFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
