import SwiftUI

/// What the lock screen player shows; back to the chosen start view
/// (Settings → Lock Screen) on every lock.
final class LockScreenState: ObservableObject {
    /// Large cover below the clock instead of the small card.
    @Published var large = false
    /// Lyrics beside the large cover.
    @Published var lyrics = false

    func reset() {
        let start = AppSettings.shared.lockScreenStart
        large = start != .compact
        lyrics = start == .lyrics
    }
}

/// The lock screen shows one thing: the music player, like on the iPhone.
/// It starts as a small glass card; clicking the cover makes it large over
/// a dark backdrop tinted by the cover, and the lyrics button adds the
/// synced lyrics beside it. Nothing at all while nothing plays.
struct LockScreenView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var lyrics: LyricsService
    @ObservedObject var state: LockScreenState
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var player

    private var spring: Animation { .spring(response: 0.5, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let info = nowPlaying.info {
                    if state.large {
                        Backdrop(image: nowPlaying.artwork, tint: nowPlaying.accent, size: size,
                                 style: settings.lockScreenBackdrop)
                            .transition(.opacity)
                        LockClock(screenHeight: size.height)
                            .transition(.opacity)
                        large(info: info, size: size)
                    } else {
                        compact(info: info)
                            .position(x: size.width / 2, y: size.height * 0.67)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.coverTint, nowPlaying.artwork != nil ? nowPlaying.accent : .white)
        .animation(spring, value: nowPlaying.info == nil)
        .animation(spring, value: state.large)
        .animation(spring, value: state.lyrics)
        .animation(.easeInOut(duration: 0.4), value: settings.lockScreenBackdrop)
    }

    /// Small card above "Touch ID or Enter Password".
    private func compact(info: NowPlayingInfo) -> some View {
        LockControls(service: nowPlaying, info: info, lyricsOn: false, onLyrics: {
            state.large = true
            state.lyrics = true
        }) {
            HStack(spacing: 10) {
                CoverArt(image: nowPlaying.artwork, cornerRadius: 8)
                    .matchedGeometryEffect(id: "cover", in: player)
                    .frame(width: 52, height: 52)
                    .onTapGesture { state.large = true }
                    .help(L("Groß anzeigen", "Show large"))
                Titles(info: info, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 390)
        .transition(.opacity)
    }

    /// Large cover under the clock with the card below; with lyrics the
    /// pair moves left and the lyrics appear on the right.
    private func large(info: NowPlayingInfo, size: CGSize) -> some View {
        let cover = min(380, size.height * 0.36)
        return HStack(alignment: .center, spacing: 72) {
            VStack(spacing: 18) {
                CoverArt(image: nowPlaying.artwork, cornerRadius: 18)
                    .matchedGeometryEffect(id: "cover", in: player)
                    .frame(width: cover, height: cover)
                    .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
                    .onTapGesture { state.large = false; state.lyrics = false }
                    .help(L("Klein anzeigen", "Show small"))
                LockControls(service: nowPlaying, info: info, lyricsOn: state.lyrics,
                             onLyrics: { state.lyrics.toggle() }) {
                    Titles(info: info, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: max(340, cover * 0.9))
                .transition(.opacity)
            }
            if state.lyrics {
                LyricsPanel(lyrics: lyrics, info: info, large: true, fontSize: 30) { nowPlaying.seek(to: $0) }
                    .frame(width: 540, height: cover + 180)
                    .transition(.opacity.combined(with: .offset(x: 40)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, size.height * 0.27)
    }
}

/// Covers the wallpaper once the cover is large: either a dark background
/// tinted by the cover (the artwork hugely blurred, a glow of its colour
/// from the lower right) or the cover itself filling the screen.
private struct Backdrop: View {
    let image: NSImage?
    let tint: Color
    let size: CGSize
    let style: LockScreenBackdrop

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
            if style != .tinted, let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: style == .coverBlurred ? 40 : 0, opaque: true)
                    .clipped()
                // Keep clock, titles and lyrics readable on bright covers.
                LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.25), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 110)
                        .opacity(0.4)
                }
                RadialGradient(colors: [tint.opacity(0.28), .clear], center: .bottomTrailing,
                               startRadius: 0, endRadius: max(size.width, size.height) * 0.75)
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Date and time at the top, in place of the system clock that the
/// backdrop covers.
private struct LockClock: View {
    let screenHeight: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
                    .font(.system(size: screenHeight * 0.022, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: screenHeight * 0.11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, screenHeight * 0.075)
        .allowsHitTesting(false)
    }
}

private struct Titles: View {
    let info: NowPlayingInfo
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(info.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

/// Glass card: a header (cover and titles), progress with times, then
/// shuffle, back, play/pause, forward and repeat. The lyrics button sits
/// at the top right.
private struct LockControls<Header: View>: View {
    @ObservedObject var service: NowPlayingService
    let info: NowPlayingInfo
    let lyricsOn: Bool
    let onLyrics: () -> Void
    @ViewBuilder var header: Header

    var body: some View {
        GlassCard {
            VStack(spacing: 14) {
                header
                    .overlay(alignment: .topTrailing) {
                        LockButton(symbol: lyricsOn ? "quote.bubble.fill" : "quote.bubble", size: 15, action: onLyrics)
                            .foregroundStyle(lyricsOn ? .white : .white.opacity(0.55))
                            .frame(width: 32, height: 28)
                            .offset(x: 8, y: -4)
                            .help(L("Songtext", "Lyrics"))
                    }
                LockProgress(service: service, info: info)
                HStack(spacing: 0) {
                    small("shuffle", active: info.isShuffling) { service.toggleShuffle() }
                    Spacer(minLength: 0)
                    LockButton(symbol: "backward.fill", size: 22) { service.send(.previous) }
                    Spacer(minLength: 0)
                    LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 30) {
                        service.send(.togglePlayPause)
                    }
                    Spacer(minLength: 0)
                    LockButton(symbol: "forward.fill", size: 22) { service.send(.next) }
                    Spacer(minLength: 0)
                    small(info.repeatMode == 2 ? "repeat.1" : "repeat", active: info.repeatMode > 1) { service.cycleRepeat() }
                }
            }
        }
    }

    private func small(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        LockButton(symbol: symbol, size: 15, action: action)
            .foregroundStyle(active ? .white : .white.opacity(0.45))
            .opacity(service.usingFallback ? 0.3 : 1)
    }
}

/// The player card in the style chosen under Settings → Lock Screen:
/// a liquid-chrome texture, clear Liquid Glass (both without a border), or
/// the classic frosted glass with a shiny rim. The transparency slider
/// fades the texture or the frosting; text stays readable on all of them.
private struct GlassCard<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let solid = 1 - min(max(settings.lockScreenTransparency, 0), 1)
        let style = settings.lockScreenCardStyle
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background {
                Group {
                    if let texture = style.texture {
                        ChromeFill(texture: texture, shape: shape, solid: solid)
                    } else if style == .clearGlass {
                        ClearGlassFill(shape: shape, solid: solid)
                    } else {
                        ClassicGlassFill(shape: shape, solid: solid)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: solid)
            }
            .overlay {
                if style == .classic { ClassicRim(shape: shape) }
            }
            .shadow(color: .black.opacity(style == .clearGlass ? 0.18 : 0.35), radius: 20, y: 10)
            .animation(.easeInOut(duration: 0.3), value: style)
    }
}

/// Liquid chrome: the texture fills the card, darkened towards the
/// buttons so white text stays readable; with more transparency the
/// wallpaper shows through.
private struct ChromeFill: View {
    let texture: String
    let shape: RoundedRectangle
    let solid: Double

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            // Overlay on a clear view so the picture fills the card without
            // making it larger.
            Color.clear.overlay {
                Image(texture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
            .opacity(0.45 + 0.55 * solid)
            LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        }
        .clipShape(shape)
    }
}

/// Clear Liquid Glass with soft light instead of a rim: brighter at the
/// upper left, a faint caustic at the lower right.
private struct ClearGlassFill: View {
    let shape: RoundedRectangle
    let solid: Double

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial).opacity(solid * 0.8)
            shape.fill(Color.black.opacity(0.08 + solid * 0.2))
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: shape)
            } else {
                shape.fill(.ultraThinMaterial).opacity(0.4)
            }
            shape.fill(RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topLeading,
                                      startRadius: 0, endRadius: 260))
            shape.fill(RadialGradient(colors: [.white.opacity(0.10), .clear], center: .bottomTrailing,
                                      startRadius: 0, endRadius: 200))
        }
    }
}

/// The earlier frosted glass with a sheen across the top.
private struct ClassicGlassFill: View {
    let shape: RoundedRectangle
    let solid: Double

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial).opacity(solid * 0.9)
            shape.fill(Color.black.opacity(solid * 0.3))
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: shape)
            } else {
                shape.fill(.ultraThinMaterial).opacity(0.35)
            }
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03), .clear],
                                      startPoint: .top, endPoint: .center))
        }
    }
}

/// Specular rim with a faint cyan/magenta fringe (classic style only).
private struct ClassicRim: View {
    let shape: RoundedRectangle

    var body: some View {
        ZStack {
            shape.strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1)
                .offset(x: -0.6, y: -0.6)
                .blur(radius: 0.6)
            shape.strokeBorder(Color(red: 1, green: 0.3, blue: 0.8).opacity(0.3), lineWidth: 1)
                .offset(x: 0.6, y: 0.6)
                .blur(radius: 0.6)
            shape.strokeBorder(
                LinearGradient(stops: [.init(color: .white.opacity(0.85), location: 0),
                                       .init(color: .white.opacity(0.25), location: 0.25),
                                       .init(color: .white.opacity(0.06), location: 0.55),
                                       .init(color: .white.opacity(0.45), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.2)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

/// Draggable progress bar with elapsed time left and remaining time right.
private struct LockProgress: View {
    @ObservedObject var service: NowPlayingService
    let info: NowPlayingInfo
    @State private var dragValue: Double?

    var body: some View {
        let info = service.info ?? self.info
        TimelineView(.periodic(from: .now, by: info.isPlaying && dragValue == nil ? 0.5 : 3600)) { context in
            let position = dragValue ?? info.elapsed(at: context.date)
            let fraction = info.duration > 0 ? min(max(position / info.duration, 0), 1) : 0
            HStack(spacing: 8) {
                Text(time(position))
                    .frame(width: 42, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                    .frame(height: dragValue == nil ? 6 : 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard info.duration > 0 else { return }
                            dragValue = Double(min(max(drag.location.x / proxy.size.width, 0), 1)) * info.duration
                        }
                        .onEnded { _ in
                            if let value = dragValue { service.seek(to: value) }
                            dragValue = nil
                        })
                }
                .frame(height: 16)
                Text("-" + time(max(0, info.duration - position)))
                    .frame(width: 46, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LockButton: View {
    let symbol: String
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
