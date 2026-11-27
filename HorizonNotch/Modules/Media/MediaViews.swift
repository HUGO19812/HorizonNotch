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
        let color = visualizerColor(cover: service.accent, theme: theme)
        let playing = service.info?.isPlaying == true
        if settings.showVisualizer {
            switch settings.compactIndicator {
            case .waves:
                LiveWaves(color: color, playing: playing)
                    .frame(width: 24, height: 14)
            case .ring:
                CompactProgressRing(service: service, color: color)
                    .frame(width: 14, height: 14)
            case .dot:
                BreathingDot(color: color, playing: playing)
                    .frame(width: 14, height: 14)
            }
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(service.accent)
        }
    }
}

/// A thin ring that fills with the song's progress; it stands still while
/// paused because the position does.
private struct CompactProgressRing: View {
    @ObservedObject var service: NowPlayingService
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let info = service.info
            let progress = (info?.duration ?? 0) > 0
                ? min(1, max(0, (info?.elapsed(at: context.date) ?? 0) / (info?.duration ?? 1))) : 0
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            .padding(1)
        }
    }
}

/// Measures the system audio while the view is on screen and music plays
/// (the tap, and macOS's recording indicator, only run then).
private struct MeasuresAudio: ViewModifier {
    let playing: Bool

    func body(content: Content) -> some View {
        content.task(id: playing) {
            guard playing else { return }
            AudioLevelMeter.shared.acquire()
            defer { AudioLevelMeter.shared.release() }
            // Runs until the view goes away or playback stops.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
    }
}

/// A dot that beats with the music: it grows and brightens with the
/// loudness and kicks on every beat. Without a signal (no permission,
/// silence) it breathes slowly instead; at rest when paused.
private struct BreathingDot: View {
    let color: Color
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
            let levels = AudioLevelMeter.shared.levels
            let pulse: Double = {
                guard playing else { return 0 }
                if levels.hasSignal { return Double(min(1, levels.level * 0.55 + levels.beat * 0.7)) }
                return (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4) + 1) / 2
            }()
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(0.7 + 0.55 * pulse)
                .opacity(0.45 + 0.55 * pulse)
        }
        .modifier(MeasuresAudio(playing: playing))
    }
}

/// The bars following the music: bass, low mids, high mids and treble.
/// Without a signal they fall back to the decorative animation.
private struct LiveWaves: View {
    let color: Color
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { _ in
            let levels = AudioLevelMeter.shared.levels
            if playing, levels.hasSignal {
                HStack(spacing: 2.5) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule()
                            .fill(color)
                            .frame(width: 3, height: 14 * CGFloat(0.25 + 0.75 * levels.bands[i]))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AudioVisualizerView(color: NSColor(color), isPlaying: playing)
            }
        }
        .modifier(MeasuresAudio(playing: playing))
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
    /// The output picker lies over the player.
    @State private var showOutputs = false
    private let positionTick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .environment(\.coverTint, service.artwork != nil ? service.accent : .white)
            .animation(.spring(response: 0.46, dampingFraction: 0.86), value: lyricsOn)
    }

    /// Lyrics beside the player – only for songs that have some.
    private var lyricsOn: Bool { settings.showLyrics && lyrics.state != .unavailable }

    @ViewBuilder
    private var content: some View {
        if let info = service.info {
            HStack(spacing: 14) {
                // One player for both layouts, only smaller beside the
                // lyrics: cover, title and artist, the lyrics button and the
                // playing app top right, the progress bar, and heart – back
                // – play – forward – output.
                VStack(alignment: .leading, spacing: lyricsOn ? 7 : 10) {
                    HStack(alignment: .center, spacing: lyricsOn ? 10 : 14) {
                        cover(info, size: lyricsOn ? 50 : 58, radius: lyricsOn ? 10 : 13)
                        TitleBlock(info: info, titleSize: lyricsOn ? 13 : 17)
                        Spacer(minLength: lyricsOn ? 4 : 8)
                        HStack(spacing: lyricsOn ? 4 : 10) {
                            ControlButton(symbol: "quote.bubble", size: 13, active: lyricsOn) {
                                settings.showLyrics = !lyricsOn
                            }
                            .disabled(lyrics.state == .unavailable)
                            .opacity(lyrics.state == .unavailable ? 0.3 : 1)
                            .help(lyrics.state == .unavailable ? L("Kein synchronisierter Songtext", "No synced lyrics")
                                  : L("Songtext", "Lyrics"))
                            if settings.showSource { SourceIcon(info: info) }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    ProgressScrubber(service: service, info: info, inline: !lyricsOn)
                    CanopyControls(service: service, info: info, showOutputs: $showOutputs)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showOutputs {
                        let close = {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showOutputs = false }
                        }
                        ZStack(alignment: .bottomTrailing) {
                            // A click beside the popup closes it.
                            Color.clear.contentShape(Rectangle()).onTapGesture(perform: close)
                            OutputPicker(service: service, close: close)
                                .padding(.bottom, 34)
                                .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.top, 2)
                // Room between the buttons and the island's edge.
                .padding(.bottom, lyricsOn ? 0 : 8)
                .padding(.horizontal, lyricsOn ? 0 : 6)
                .frame(width: lyricsOn ? 240 : nil)
                if lyricsOn {
                    LyricsPanel(lyrics: lyrics, info: info, large: settings.lyricsLarge) { service.seek(to: $0) }
                        .transition(.lyricsReveal)
                }
            }
            // Loaded for every song, so the button knows whether there
            // are lyrics (LRCLIB, cached).
            .task(id: info.artist + "|" + info.title) { lyrics.load(for: info) }
            // The player's exact position now and then, so the lyrics
            // stay in step.
            .onReceive(positionTick) { _ in if lyricsOn { service.syncPosition() } }
        } else {
            NothingPlayingView()
        }
    }

    private func cover(_ info: NowPlayingInfo, size: CGFloat, radius: CGFloat) -> some View {
        CoverArt(image: service.artwork, cornerRadius: radius)
            .matchedGeometryEffect(id: "cover", in: player)
            .frame(width: size, height: size)
            .background { if settings.albumTint { AlbumGlow(image: service.artwork, cornerRadius: radius) } }
            // The large player from the lock screen, full screen.
            .onTapGesture {
                if let controller = LockScreenController.current {
                    controller.showPlayer()
                } else {
                    service.openPlayerApp()
                }
            }
            .help(L("Großer Player", "Large player"))
    }
}
/// The app that plays, as its icon (top right of the player).
private struct SourceIcon: View {
    let info: NowPlayingInfo

    var body: some View {
        Group {
            if let bundle = info.bundleID,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
            }
        }
        .help(info.appName ?? L("Quelle", "Source"))
    }
}

/// Shuffle, back, play/pause, forward and repeat in the middle, the output
/// device on the right – like Pro Notch.
private struct ProControls: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var output = AudioOutput.shared
    let info: NowPlayingInfo

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 30, height: 1)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                ControlButton(symbol: "shuffle", size: 13, active: info.isShuffling) { service.toggleShuffle() }
                    .opacity(service.usingFallback ? 0.3 : 1)
                    .help(L("Zufallswiedergabe", "Shuffle"))
                ControlButton(symbol: "backward.fill", size: 19) { service.send(.previous) }
                ControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 25) {
                    service.send(.togglePlayPause)
                }
                ControlButton(symbol: "forward.fill", size: 19) { service.send(.next) }
                ControlButton(symbol: info.repeatMode == 2 ? "repeat.1" : "repeat", size: 13,
                              active: info.repeatMode > 1) { service.cycleRepeat() }
                    .opacity(service.usingFallback ? 0.3 : 1)
                    .help(L("Wiederholen", "Repeat"))
            }
            Spacer(minLength: 0)
            Image(systemName: output.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 30)
                .help(output.deviceName)
        }
    }
}

/// Heart, back, play/pause, forward and the output device, spread evenly
/// across the width – like Canopy. The output button opens the output
/// picker over the player (see MediaExpandedView).
private struct CanopyControls: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var output = AudioOutput.shared
    let info: NowPlayingInfo
    @Binding var showOutputs: Bool

    var body: some View {
        buttons.frame(height: 32)
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            Button { service.toggleLike() } label: {
                Image(systemName: service.liked ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(service.liked ? Color(red: 0.98, green: 0.33, blue: 0.47) : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    // Spotify: no state to show, a beat confirms the press.
                    .symbolEffect(.bounce, value: service.likePulse)
                    .frame(width: 38, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .opacity(service.canLike ? 1 : 0.3)
            .disabled(!service.canLike)
            .help(!service.canLike ? L("Nur mit Spotify oder Apple Music", "Only with Spotify or Apple Music")
                  : (service.likeKnown ? L("Favorit", "Favourite")
                     : L("Zu Lieblingssongs hinzufügen oder entfernen (Spotify zeigt den Stand nicht)",
                         "Add to or remove from Liked Songs (Spotify doesn't share the state)")))
            Spacer(minLength: 0)
            ControlButton(symbol: "backward.fill", size: 18) { service.send(.previous) }
            Spacer(minLength: 0)
            ControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                service.send(.togglePlayPause)
            }
            Spacer(minLength: 0)
            ControlButton(symbol: "forward.fill", size: 18) { service.send(.next) }
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showOutputs = true }
            } label: {
                Image(systemName: output.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 38, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help(L("Ausgabe – \(output.deviceName)", "Output – \(output.deviceName)"))
        }
    }
}

/// Where the sound goes: the volume on top, below every output device –
/// a click switches to it. Closes by itself after a few quiet seconds.
private struct OutputPicker: View {
    @ObservedObject var service: NowPlayingService
    let close: () -> Void
    @ObservedObject private var output = AudioOutput.shared

    var body: some View {
        VStack(spacing: 6) {
            // System and player volume share one row, so the devices keep
            // their room.
            HStack(spacing: 4) {
                if let name = service.playerVolumeName {
                    PlayerVolumeRow(service: service, name: name)
                        .frame(width: 128)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16)
                }
                VolumeRow(close: close)
            }
            .frame(height: 26)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(output.devices) { device in
                        let current = device.id == output.currentID
                        Button { output.select(device) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.symbol)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(width: 18)
                                Text(device.name)
                                    .font(.system(size: 11.5, weight: current ? .semibold : .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if current {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                }
                            }
                            .foregroundStyle(.white.opacity(current ? 1 : 0.7))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(current ? 0.12 : 0)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(output.devices.count, 3)) * 28)
        }
        .padding(8)
        .frame(width: service.playerVolumeName == nil ? 236 : 372)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

/// The player's own volume (Spotify / Apple Music) below the system one:
/// its icon, a bar to drag, the level.
private struct PlayerVolumeRow: View {
    @ObservedObject var service: NowPlayingService
    let name: String
    @State private var level: Double?
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: name == "Spotify" ? "dot.radiowaves.right" : "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 20)
                .help(name)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white.opacity(0.7))
                        .frame(width: proxy.size.width * (level ?? 0))
                }
                .frame(height: dragging ? 10 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        let value = Double(min(max(gesture.location.x / proxy.size.width, 0), 1))
                        level = value
                        service.setPlayerVolume(value)
                    }
                    .onEnded { _ in dragging = false })
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
            .frame(height: 20)
        }
        .padding(.leading, 2)
        .help(L("Lautstärke nur in \(name)", "Volume of \(name) only"))
        .task {
            let read = await Task.detached { service.readPlayerVolume() }.value
            if !dragging { level = read }
        }
    }
}

/// Speaker (click = mute), a bar to drag or scroll, the level, and a
/// close button. Closes by itself after a few quiet seconds.
private struct VolumeRow: View {
    let close: () -> Void
    @ObservedObject private var output = AudioOutput.shared
    @State private var level: Double = Double(AudioOutput.shared.volume)
    @State private var muted = AudioOutput.shared.isMuted
    @State private var lastTouch = Date()
    @State private var dragging = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                muted.toggle()
                AudioOutput.shared.isMuted = muted
                lastTouch = Date()
            } label: {
                Image(systemName: speaker)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26)
            }
            .buttonStyle(.plain)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white.opacity(muted ? 0.35 : 0.9))
                        .frame(width: proxy.size.width * level)
                }
                .frame(height: dragging ? 10 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        set(Double(min(max(gesture.location.x / proxy.size.width, 0), 1)))
                    }
                    .onEnded { _ in dragging = false })
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
            .frame(height: 20)
            Text("\(Int((level * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 28, alignment: .trailing)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .onReceive(tick) { _ in
            if !dragging && Date().timeIntervalSince(lastTouch) > 4 { close() }
        }
        .help(output.deviceName)
    }

    private var speaker: String {
        if muted || level == 0 { return "speaker.slash.fill" }
        return level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }

    private func set(_ value: Double) {
        level = value
        lastTouch = Date()
        AudioOutput.shared.volume = Float(value)
        if muted && value > 0 {
            muted = false
            AudioOutput.shared.isMuted = false
        }
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
/// Lyrics like Apple Music: every line in bold, the sung one bright and
/// sharp, the others dimmed and slightly blurred, gliding upwards.
struct LyricsPanel: View {
    @ObservedObject var lyrics: LyricsService
    let info: NowPlayingInfo
    let large: Bool
    /// Overrides the text size (the lock screen uses bigger lines).
    var fontSize: CGFloat?
    /// Jumps playback to a position (a tapped line).
    let onSeek: (Double) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            switch lyrics.state {
            case .loaded:
                TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.1 : 3600)) { context in
                    // The adjustable offset makes up for lyrics files that
                    // run early or late against this recording.
                    let position = info.elapsed(at: context.date) + settings.lyricsOffset
                    let current = lyrics.index(at: position)
                    LyricsScroller(lines: lyrics.lines, current: current,
                                   sung: current.map { lyrics.sungWords(in: $0, at: position) } ?? 0,
                                   large: large, fontSize: fontSize, onSeek: onSeek)
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
            .font(.system(size: fontSize ?? (large ? 17 : 15), weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Lyrics lines stacked top to bottom and shifted so the current one sits
/// at `anchor` (a share of the height). Each line moves on its own spring,
/// a little later the further below the current line it is: the lines
/// follow one another like a wave instead of sliding as one block.
struct CascadingLines<Row: View>: View {
    let count: Int
    let current: Int?
    let spacing: CGFloat
    var anchor: CGFloat = 0.42
    @ViewBuilder let row: (Int) -> Row
    @State private var heights: [Int: CGFloat] = [:]
    /// No animation until the lines are measured (no slide-in on appear).
    @State private var measured = false

    var body: some View {
        GeometryReader { proxy in
            let focus = min(current ?? 0, max(count - 1, 0))
            let above = (0..<focus).reduce(CGFloat(0)) { $0 + (heights[$1] ?? 0) + spacing }
            let shift = proxy.size.height * anchor - above - (heights[focus] ?? 0) / 2
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    row(index)
                        .background(GeometryReader { line in
                            Color.clear.preference(key: LineHeights.self, value: [index: line.size.height])
                        })
                        .offset(y: shift)
                        .animation(measured ? .spring(response: 0.62, dampingFraction: 0.8)
                                    .delay(Self.delay(index, focus)) : nil, value: shift)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onPreferenceChange(LineHeights.self) { new in
                heights = new
                if !measured { DispatchQueue.main.async { measured = true } }
            }
        }
        .clipped()
    }

    /// The line before the current one and all above move at once; below
    /// it, each line 35 ms after the one above (at most 10 steps).
    private static func delay(_ index: Int, _ focus: Int) -> Double {
        Double(min(max(index - focus + 1, 0), 10)) * 0.035
    }
}

private struct LineHeights: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LyricsScroller: View {
    let lines: [LyricsService.Line]
    let current: Int?
    /// Words of the current line already sung (they turn fully white).
    let sung: Int
    let large: Bool
    var fontSize: CGFloat?
    let onSeek: (Double) -> Void
    @State private var hovered: Int?
    @Environment(\.coverTint) private var tint

    var body: some View {
        CascadingLines(count: lines.count, current: current,
                       spacing: fontSize.map { $0 * 0.55 } ?? (large ? 10 : 8), anchor: 0.36) { index in
            let line = lines[index]
            let isCurrent = index == current
            let isPast = current.map { index < $0 } ?? false
            let isHovered = hovered == index && !isCurrent
            // One Text whether current or not: swapping views made the new
            // current line jump to its place instead of gliding.
            (isCurrent && !line.text.isEmpty ? highlighted(line)
                : Text(line.text.isEmpty ? "♪" : line.text)
                    .foregroundStyle(.white.opacity(isHovered ? 0.65 : (isPast ? 0.22 : 0.34))))
            .font(.system(size: fontSize ?? (large ? 19 : 16), weight: .bold))
            // The new line grows in with a short soft glow; only these
            // spring, the place follows the cascade.
            .animation(.spring(response: 0.45, dampingFraction: 0.72)) {
                $0.blur(radius: isCurrent || isHovered ? 0 : 1.1)
                    .scaleEffect(isCurrent ? 1 : 0.94, anchor: .leading)
                    .shadow(color: .white.opacity(isCurrent ? 0.25 : 0), radius: 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Click a line to jump there.
            .onTapGesture { onSeek(line.time) }
            .onHover { inside in
                if inside { hovered = index } else if hovered == index { hovered = nil }
            }
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .animation(.easeOut(duration: 0.18), value: sung)
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

/// Nothing plays: the player itself, greyed out and waiting – an empty
/// cover with a note, "Not playing", resting dots instead of the
/// visualizer, an empty bar with "-:--", and the buttons. Play starts the
/// chosen player (Spotify or Music) right away.
private struct NothingPlayingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var output = AudioOutput.shared
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 58, height: 58)
                    .overlay(Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45)))
                Text(starting ? L("Wird gestartet …", "Starting …") : L("Gerade läuft nichts", "Not playing"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { _ in
                        Circle().fill(Color.white.opacity(0.35)).frame(width: 2.5, height: 2.5)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("-:--")
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 7)
                Text("-:--")
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.3))
            HStack(spacing: 0) {
                Color.clear.frame(width: 38, height: 32)
                Spacer(minLength: 0)
                dimmed("backward.fill", size: 18)
                Spacer(minLength: 0)
                Button(action: startPlayer) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 42, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .help(playerName.map { L("\($0) starten", "Start \($0)") } ?? "")
                Spacer(minLength: 0)
                dimmed("forward.fill", size: 18)
                Spacer(minLength: 0)
                Image(systemName: output.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 38, height: 32)
            }
            .frame(height: 32)
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .padding(.horizontal, 6)
    }

    private func dimmed(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(0.3))
            .frame(width: size + 18, height: 32)
    }

    /// The player the play button opens: the chosen source, else Spotify if
    /// it is installed, else Music.
    private var player: (bundle: String, name: String)? {
        let installed = { (id: String) in NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
        switch settings.mediaSource {
        case .spotify: return ("com.spotify.client", "Spotify")
        case .music: return ("com.apple.Music", "Music")
        case .auto:
            return installed("com.spotify.client") ? ("com.spotify.client", "Spotify") : ("com.apple.Music", "Music")
        }
    }

    private var playerName: String? {
        guard let player else { return nil }
        return player.bundle == "com.apple.Music" ? L("Musik", "Music") : player.name
    }

    private func startPlayer() {
        guard let player else { return }
        starting = true
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(player.name)\" to play")?.executeAndReturnError(&error)
            DispatchQueue.main.async { starting = false }
        }
    }
}

/// Progress bar that can be dragged. Re-renders twice a second while the
/// island is open and music plays; nothing ticks otherwise.
private struct ProgressScrubber: View {
    @ObservedObject var service: NowPlayingService
    let info: NowPlayingInfo
    /// Times left and right of the bar (Canopy) instead of below it.
    var inline = false
    @State private var dragValue: Double?

    var body: some View {
        // The service's latest state: right after a seek it already holds
        // the new position, even before the parent view re-renders.
        let info = service.info ?? self.info
        TimelineView(.periodic(from: .now, by: info.isPlaying && dragValue == nil ? 0.5 : 3600)) { context in
            let duration = max(info.duration, 0.01)
            let position = dragValue ?? info.elapsed(at: context.date)
            let bar = GeometryReader { proxy in
                let fraction = CGFloat(min(max(position / duration, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(inline ? Color.white.opacity(0.5) : service.accent.opacity(0.95))
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: dragValue == nil ? (inline ? 7 : 6) : 10)
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
            if inline {
                HStack(spacing: 12) {
                    Text(Self.format(position))
                    bar
                    Text(info.duration > 0 ? Self.format(max(0, info.duration - position)) : "")
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            } else {
                VStack(spacing: 3) {
                    bar
                    HStack {
                        Text(Self.format(position))
                        Spacer()
                        Text(info.duration > 0 ? "-" + Self.format(max(0, info.duration - position)) : "")
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                }
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
        // Only the press scale gets the quick spring: an animation over the
        // whole label would also take over any move the click starts (the
        // clicked button would jump ahead of the others).
        configuration.label
            .animation(.spring(response: 0.25, dampingFraction: 0.6)) {
                $0.scaleEffect(configuration.isPressed ? 0.86 : 1)
            }
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
