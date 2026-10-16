import SwiftUI

/// What the lock screen player shows; reset to the small player on every lock.
final class LockScreenState: ObservableObject {
    /// Large cover below the clock instead of the small card.
    @Published var large = false
    /// Lyrics beside the large cover.
    @Published var lyrics = false

    func reset() {
        large = false
        lyrics = false
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
    @Namespace private var player

    private var spring: Animation { .spring(response: 0.5, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let info = nowPlaying.info {
                    if state.large {
                        Backdrop(image: nowPlaying.artwork, tint: nowPlaying.accent, size: size)
                            .transition(.opacity)
                        LockClock(screenHeight: size.height)
                            .transition(.opacity)
                        large(info: info, size: size)
                    } else {
                        compact(info: info)
                            .position(x: size.width / 2, y: size.height * 0.68)
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
    }

    /// Small card above "Touch ID or Enter Password".
    private func compact(info: NowPlayingInfo) -> some View {
        LockControls(service: nowPlaying, info: info, lyricsOn: false, onLyrics: {
            state.large = true
            state.lyrics = true
        }) {
            HStack(spacing: 10) {
                CoverArt(image: nowPlaying.artwork, cornerRadius: 6)
                    .matchedGeometryEffect(id: "cover", in: player)
                    .frame(width: 38, height: 38)
                    .onTapGesture { state.large = true }
                    .help(L("Groß anzeigen", "Show large"))
                Titles(info: info, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 300)
        .transition(.opacity)
    }

    /// Large cover under the clock with the card below; with lyrics the
    /// pair moves left and the lyrics appear on the right.
    private func large(info: NowPlayingInfo, size: CGSize) -> some View {
        let cover = min(300, size.height * 0.3)
        return HStack(alignment: .center, spacing: 64) {
            VStack(spacing: 16) {
                CoverArt(image: nowPlaying.artwork, cornerRadius: 14)
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
                .frame(width: max(260, cover * 0.85))
                .transition(.opacity)
            }
            if state.lyrics {
                LyricsPanel(lyrics: lyrics, info: info, large: true, fontSize: 24) { nowPlaying.seek(to: $0) }
                    .frame(width: 440, height: cover + 150)
                    .transition(.opacity.combined(with: .offset(x: 40)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, size.height * 0.29)
    }
}

/// Covers the wallpaper with a dark background tinted by the cover: the
/// artwork hugely blurred, a glow of its colour from the lower right.
private struct Backdrop: View {
    let image: NSImage?
    let tint: Color
    let size: CGSize

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
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
        VStack(alignment: alignment, spacing: 1) {
            Text(info.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                .font(.system(size: 11))
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
            VStack(spacing: 10) {
                header
                    .overlay(alignment: .topTrailing) {
                        LockButton(symbol: lyricsOn ? "quote.bubble.fill" : "quote.bubble", size: 11, action: onLyrics)
                            .foregroundStyle(lyricsOn ? .white : .white.opacity(0.55))
                            .frame(width: 26, height: 22)
                            .offset(x: 8, y: -4)
                            .help(L("Songtext", "Lyrics"))
                    }
                LockProgress(service: service, info: info)
                HStack(spacing: 0) {
                    small("shuffle", active: info.isShuffling) { service.toggleShuffle() }
                    Spacer(minLength: 0)
                    LockButton(symbol: "backward.fill", size: 17) { service.send(.previous) }
                    Spacer(minLength: 0)
                    LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                        service.send(.togglePlayPause)
                    }
                    Spacer(minLength: 0)
                    LockButton(symbol: "forward.fill", size: 17) { service.send(.next) }
                    Spacer(minLength: 0)
                    small(info.repeatMode == 2 ? "repeat.1" : "repeat", active: info.repeatMode > 1) { service.cycleRepeat() }
                }
            }
        }
    }

    private func small(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        LockButton(symbol: symbol, size: 11, action: action)
            .foregroundStyle(active ? .white : .white.opacity(0.45))
            .opacity(service.usingFallback ? 0.3 : 1)
    }
}

/// Translucent, lightly outlined card: Liquid Glass on macOS 26+.
private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let padded = content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        Group {
            if #available(macOS 26.0, *) {
                padded.glassEffect(.regular.tint(.black.opacity(0.15)), in: shape)
            } else {
                padded.background(shape.fill(.ultraThinMaterial))
                    .background(shape.fill(Color.black.opacity(0.2)))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
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
                    .frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                    .frame(height: dragValue == nil ? 4 : 6)
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
                .frame(height: 12)
                Text("-" + time(max(0, info.duration - position)))
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
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
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
