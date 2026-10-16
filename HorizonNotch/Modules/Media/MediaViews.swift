import AppKit
import SwiftUI

// MARK: - Compact

struct MediaCompactCover: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        CoverArt(image: service.artwork, cornerRadius: 6)
            .frame(width: 22, height: 22)
    }
}

/// Visualizer colour from Settings → Appearance.
func visualizerColor(cover: Color, theme: IslandTheme) -> Color {
    switch AppSettings.shared.visualizerColor {
    case .cover: return cover
    case .accent: return theme.accent
    case .white: return .white
    }
}

struct MediaCompactVisualizer: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if settings.showVisualizer {
            AudioVisualizerView(color: NSColor(visualizerColor(cover: service.accent, theme: theme)), isPlaying: service.info?.isPlaying == true)
                .frame(width: 24, height: 14)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(service.accent)
        }
    }
}

// MARK: - Expanded

/// The lyrics field opening: it unrolls from the player towards the
/// right, sliding in and coming into focus. Closing reverses it quickly.
private struct LyricsReveal: ViewModifier {
    /// 0 = hidden, 1 = fully shown.
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: max(0.001, progress), anchor: .leading)
            }
            .offset(x: 28 * (1 - progress))
            .blur(radius: 6 * (1 - progress))
            .opacity(Double(0.2 + 0.8 * progress))
    }
}

extension AnyTransition {
    static var lyricsReveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: LyricsReveal(progress: 0), identity: LyricsReveal(progress: 1))
                .animation(.spring(response: 0.5, dampingFraction: 0.9).delay(0.06)),
            removal: .modifier(active: LyricsReveal(progress: 0), identity: LyricsReveal(progress: 1))
                .combined(with: .opacity)
                .animation(.easeIn(duration: 0.18)))
    }
}

/// Highlight colour taken from the album cover (white without a cover).
private struct CoverTintKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

extension EnvironmentValues {
    var coverTint: Color {
        get { self[CoverTintKey.self] }
        set { self[CoverTintKey.self] = newValue }
    }
}

struct MediaExpandedView: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.islandTheme) private var theme
    /// Cover, title, progress bar and controls glide between the two
    /// layouts instead of fading; only the lyrics field is new.
    @Namespace private var player

    var body: some View {
        content
            .environment(\.coverTint, service.artwork != nil ? service.accent : .white)
            .animation(.spring(response: 0.46, dampingFraction: 0.86), value: settings.showLyrics)
    }

    @ViewBuilder
    private var content: some View {
        if let info = service.info {
            HStack(spacing: 14) {
                if settings.showLyrics {
                    // Smaller player on the left, lyrics in their own field.
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            cover(info, size: 50, radius: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                TitleBlock(info: info, titleSize: 13)
                                    .matchedGeometryEffect(id: "title", in: player, properties: .position, anchor: .topLeading)
                                if settings.showSource { SourceLabel(info: info).transition(.opacity) }
                            }
                        }
                        ProgressScrubber(service: service, info: info)
                            .matchedGeometryEffect(id: "progress", in: player)
                        MediaControls(service: service, info: info, compact: true)
                            .matchedGeometryEffect(id: "controls", in: player)
                    }
                    .frame(width: 232)
                    .transition(.opacity)
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(spacing: 6) {
                            cover(info, size: settings.showSource ? 80 : 92, radius: 14)
                            if settings.showSource {
                                SourceLabel(info: info)
                                    .frame(width: 80)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                TitleBlock(info: info, titleSize: 14)
                                    .matchedGeometryEffect(id: "title", in: player, properties: .position, anchor: .topLeading)
                                Spacer(minLength: 8)
                                AudioVisualizerView(color: NSColor(visualizerColor(cover: service.accent, theme: theme)), isPlaying: info.isPlaying, barCount: 5)
                                    .frame(width: 26, height: 16)
                                    .padding(.top, 2)
                            }
                            ProgressScrubber(service: service, info: info)
                                .matchedGeometryEffect(id: "progress", in: player)
                            MediaControls(service: service, info: info, compact: false)
                                .matchedGeometryEffect(id: "controls", in: player)
                        }
                    }
                    .transition(.opacity)
                }
                if settings.showLyrics {
                    LyricsPanel(lyrics: lyrics, info: info, large: settings.lyricsLarge) { service.seek(to: $0) }
                        .transition(.lyricsReveal)
                }
            }
        } else {
            NothingPlayingView()
        }
    }

    private func cover(_ info: NowPlayingInfo, size: CGFloat, radius: CGFloat) -> some View {
        CoverArt(image: service.artwork, cornerRadius: radius)
            .matchedGeometryEffect(id: "cover", in: player)
            .frame(width: size, height: size)
            .background { if settings.albumTint { AlbumGlow(image: service.artwork, cornerRadius: radius) } }
            .onTapGesture { service.openPlayerApp() }
            .help(info.appName ?? "")
    }
}

/// Where the music comes from: the player's icon and name.
private struct SourceLabel: View {
    let info: NowPlayingInfo

    var body: some View {
        HStack(spacing: 4) {
            if let bundle = info.bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(info.appName ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .help(L("Quelle", "Source"))
    }
}

private struct TitleBlock: View {
    let info: NowPlayingInfo
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)
            Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                .font(.system(size: titleSize - 2))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

private struct MediaControls: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var output = AudioOutput.shared
    @ObservedObject private var settings = AppSettings.shared
    let info: NowPlayingInfo
    let compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            ControlButton(symbol: "shuffle", size: compact ? 11 : 12, active: info.isShuffling) { service.toggleShuffle() }
                .opacity(service.usingFallback ? 0.3 : 1)
            Spacer(minLength: 0)
            ControlButton(symbol: "backward.fill", size: compact ? 14 : 16) { service.send(.previous) }
            Spacer(minLength: 0)
            ControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: compact ? 19 : 22) {
                service.send(.togglePlayPause)
            }
            Spacer(minLength: 0)
            ControlButton(symbol: "forward.fill", size: compact ? 14 : 16) { service.send(.next) }
            Spacer(minLength: 0)
            ControlButton(symbol: "quote.bubble", size: compact ? 11 : 12, active: settings.showLyrics) {
                settings.showLyrics.toggle()
            }
            .help(L("Songtext", "Lyrics"))
            if !compact {
                Image(systemName: output.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .help(output.deviceName)
            }
        }
    }
}

/// Lyrics like Apple Music: every line in bold, the sung one bright and
/// sharp, the others dimmed and slightly blurred, gliding upwards.
private struct LyricsPanel: View {
    @ObservedObject var lyrics: LyricsService
    let info: NowPlayingInfo
    let large: Bool
    /// Jumps playback to a position (a tapped line).
    let onSeek: (Double) -> Void

    var body: some View {
        Group {
            switch lyrics.state {
            case .loaded:
                TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.1 : 3600)) { context in
                    let position = info.elapsed(at: context.date)
                    let current = lyrics.index(at: position)
                    LyricsScroller(lines: lyrics.lines, current: current,
                                   sung: current.map { lyrics.sungWords(in: $0, at: position) } ?? 0,
                                   large: large, onSeek: onSeek)
                }
            case .loading:
                status(L("Songtext wird geladen …", "Loading lyrics …"))
            case .unavailable, .idle:
                status(L("Kein synchronisierter Songtext", "No synced lyrics"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { lyrics.load(for: info) }
        .onChange(of: info.title + info.artist) { _, _ in lyrics.load(for: info) }
    }

    private func status(_ message: String) -> some View {
        Text(message)
            .font(.system(size: large ? 17 : 15, weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct LyricsScroller: View {
    let lines: [LyricsService.Line]
    let current: Int?
    /// Words of the current line already sung (they turn fully white).
    let sung: Int
    let large: Bool
    let onSeek: (Double) -> Void
    @State private var hovered: Int?
    @Environment(\.coverTint) private var tint

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: large ? 10 : 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let isCurrent = index == current
                        let isPast = current.map { index < $0 } ?? false
                        let isHovered = hovered == index && !isCurrent
                        Group {
                            if isCurrent && !line.text.isEmpty {
                                highlighted(line)
                            } else {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .foregroundStyle(.white.opacity(isCurrent ? 1 : (isHovered ? 0.65 : (isPast ? 0.22 : 0.34))))
                            }
                        }
                            .font(.system(size: large ? 19 : 16, weight: .bold))
                            .blur(radius: isCurrent || isHovered ? 0 : 1.1)
                            .scaleEffect(isCurrent ? 1 : 0.96, anchor: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            // Click a line to jump there.
                            .onTapGesture { onSeek(line.time) }
                            .onHover { inside in
                                if inside { hovered = index } else if hovered == index { hovered = nil }
                            }
                            .animation(.easeOut(duration: 0.15), value: isHovered)
                            .id(index)
                    }
                }
                // Room so the first and last lines can reach the focus point.
                .padding(.vertical, 40)
            }
            .scrollDisabled(true)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { proxy.scrollTo(current ?? 0, anchor: UnitPoint(x: 0, y: 0.32)) }
            .onChange(of: current) { _, index in
                withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) {
                    proxy.scrollTo(index ?? 0, anchor: UnitPoint(x: 0, y: 0.32))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: current)
            .animation(.easeOut(duration: 0.18), value: sung)
        }
    }

    private var sungColor: Color {
        switch AppSettings.shared.lyricsColorMode {
        case .music: return .white
        case .cover: return tint
        case .fixed: return Color(hex: AppSettings.shared.lyricsFixedColor) ?? .white
        }
    }

    /// The whole line slightly grey, the words sung so far in the highlight colour.
    private func highlighted(_ line: LyricsService.Line) -> Text {
        let words = line.words
        let done = min(sung, words.count)
        let sungText = words.prefix(done).joined(separator: " ")
        let restText = words.dropFirst(done).joined(separator: " ")
        return Text(sungText).foregroundStyle(sungColor)
            + Text(done > 0 && !restText.isEmpty ? " " + restText : restText).foregroundStyle(.white.opacity(0.45))
    }
}

private struct NothingPlayingView: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35)))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Gerade läuft nichts", "Nothing playing"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("Starte Musik, Spotify oder ein Video im Browser.",
                       "Start Music, Spotify or a video in your browser."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }
}

/// Progress bar that can be dragged. Re-renders twice a second while the
/// island is open and music plays; nothing ticks otherwise.
private struct ProgressScrubber: View {
    @ObservedObject var service: NowPlayingService
    let info: NowPlayingInfo
    @State private var dragValue: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: info.isPlaying && dragValue == nil ? 0.5 : 3600)) { context in
            let duration = max(info.duration, 0.01)
            let position = dragValue ?? info.elapsed(at: context.date)
            VStack(spacing: 3) {
                GeometryReader { proxy in
                    let fraction = CGFloat(min(max(position / duration, 0), 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(service.accent.opacity(0.95))
                            .frame(width: proxy.size.width * fraction)
                    }
                    .frame(height: dragValue == nil ? 4 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard info.duration > 0 else { return }
                            let x = min(max(gesture.location.x / proxy.size.width, 0), 1)
                            dragValue = Double(x) * info.duration
                        }
                        .onEnded { _ in
                            if let value = dragValue { service.seek(to: value) }
                            dragValue = nil
                        })
                    .animation(.easeOut(duration: 0.15), value: dragValue == nil)
                }
                .frame(height: 12)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text(info.duration > 0 ? "-" + Self.format(max(0, info.duration - position)) : "")
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var active = false
    @Environment(\.coverTint) private var tint
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? tint : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 18, height: size + 14)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The cover's own colours as a soft glow just behind it.
struct AlbumGlow: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(1.12)
                .blur(radius: 16)
                .opacity(0.75)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

struct CoverArt: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: image)
    }
}
