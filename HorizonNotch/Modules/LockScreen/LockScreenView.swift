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

/// Data the lock screen shows besides the music (set by the app delegate).
enum LockScreenSources {
    static weak var weather: WeatherService?
}

/// The lock screen, in the style of Canopy: a small clear Liquid Glass
/// player above the password field and, under the clock, a row with the
/// weather, battery and headphones. Clicking the cover lets the artwork
/// fill the screen with a large cover under a glass clock tinted in its
/// colours; the lyrics button adds the synced lyrics, word by word.
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
                if let info = nowPlaying.info, state.large {
                    Backdrop(image: nowPlaying.artwork, tint: nowPlaying.accent, size: size,
                             style: settings.lockScreenBackdrop)
                        .transition(.opacity)
                    // The backdrop covers the system clock: draw our own.
                    GlassClock(screenHeight: size.height, tint: nowPlaying.artwork != nil ? nowPlaying.accent : nil)
                        .transition(.opacity)
                    large(info: info, size: size)
                } else {
                    if settings.lockScreenStatusRow {
                        // Just below the system clock.
                        StatusRow(screenHeight: size.height)
                            .position(x: size.width / 2, y: size.height * 0.285)
                            .transition(.opacity)
                    }
                    if let info = nowPlaying.info {
                        compact(info: info)
                            .position(x: size.width / 2, y: size.height * 0.66)
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

    /// Small glass card above "Touch ID or Enter Password".
    private func compact(info: NowPlayingInfo) -> some View {
        LiquidPlayerCard(service: nowPlaying, info: info, lyricsOn: false,
                         onLyrics: { state.large = true; state.lyrics = true }) {
            CoverArt(image: nowPlaying.artwork, cornerRadius: 9)
                .matchedGeometryEffect(id: "cover", in: player)
                .frame(width: 46, height: 46)
                .onTapGesture { state.large = true }
                .help(L("Groß anzeigen", "Show large"))
        }
        .frame(width: 310)
        .transition(.opacity)
    }

    /// Large cover under the clock with the card below; with lyrics the
    /// pair moves left and the lyrics appear on the right.
    private func large(info: NowPlayingInfo, size: CGSize) -> some View {
        let cover = min(360, size.height * 0.34)
        return HStack(alignment: .center, spacing: 72) {
            VStack(spacing: 22) {
                CoverArt(image: nowPlaying.artwork, cornerRadius: 10)
                    .matchedGeometryEffect(id: "cover", in: player)
                    .frame(width: cover, height: cover)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                    .onTapGesture { state.large = false; state.lyrics = false }
                    .help(L("Klein anzeigen", "Show small"))
                LiquidPlayerCard(service: nowPlaying, info: info, lyricsOn: state.lyrics,
                                 onLyrics: { state.lyrics.toggle() }) { EmptyView() }
                    .frame(width: min(cover * 0.72, 260))
                    .transition(.opacity)
            }
            if state.lyrics {
                LyricsPanel(lyrics: lyrics, info: info, large: true, fontSize: 30) { nowPlaying.seek(to: $0) }
                    .frame(width: 540, height: cover + 160)
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

/// Date and time in Liquid Glass, like the macOS lock screen clock: rounded
/// serif digits that look cut from glass, tinted by the cover when there
/// is one. Drawn when the artwork covers the system clock.
private struct GlassClock: View {
    let screenHeight: CGFloat
    let tint: Color?

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(appLocale)))
                    .font(.system(size: screenHeight * 0.026, weight: .semibold, design: .serif))
                    .foregroundStyle(glass)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: screenHeight * 0.12, weight: .bold, design: .serif))
                    .foregroundStyle(glass)
                    // Bright rim on top, a darker edge below: thick glass.
                    .overlay {
                        Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                            .font(.system(size: screenHeight * 0.12, weight: .bold, design: .serif))
                            .foregroundStyle(LinearGradient(colors: [.white.opacity(0.75), .clear, .clear, .white.opacity(0.25)],
                                                            startPoint: .top, endPoint: .bottom))
                            .blendMode(.plusLighter)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, screenHeight * 0.078)
        .allowsHitTesting(false)
    }

    private var glass: LinearGradient {
        let base = tint ?? Color(red: 0.75, green: 0.88, blue: 0.97)
        return LinearGradient(colors: [.white.opacity(0.95), base.opacity(0.9), base.opacity(0.65)],
                              startPoint: .top, endPoint: .bottom)
    }
}

/// Weather, battery and headphones in one quiet row under the clock.
private struct StatusRow: View {
    let screenHeight: CGFloat
    @ObservedObject private var power = PowerSource.shared
    @ObservedObject private var output = AudioOutput.shared

    var body: some View {
        HStack(spacing: 22) {
            if let report = LockScreenSources.weather?.report {
                item(WeatherCode.symbol(report.code, isDay: report.isDay), "\(Int(report.temperature.rounded()))°")
            }
            if power.state.hasBattery {
                item(power.state.isCharging || power.state.isPluggedIn ? "bolt.fill" : "battery.75percent",
                     "\(power.state.percent) %")
            }
            if output.isBluetooth {
                item(output.symbol, nil)
            }
        }
        .font(.system(size: max(14, screenHeight * 0.019), weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .allowsHitTesting(false)
    }

    private func item(_ symbol: String, _ text: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
    }
}

/// The player card: clear Liquid Glass (its bright, refracting edge comes
/// from the system on macOS 26), artwork and titles, a waveform while
/// playing, progress, the three buttons and the output device.
private struct LiquidPlayerCard<Artwork: View>: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var output = AudioOutput.shared
    @ObservedObject private var settings = AppSettings.shared
    let info: NowPlayingInfo
    let lyricsOn: Bool
    let onLyrics: () -> Void
    @ViewBuilder var artwork: Artwork

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let solid = 1 - min(max(settings.lockScreenTransparency, 0), 1)
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 11) {
                artwork
                VStack(alignment: Artwork.self == EmptyView.self ? .center : .leading, spacing: 1) {
                    Text(info.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: Artwork.self == EmptyView.self ? .center : .leading)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .symbolEffect(.variableColor.iterative, isActive: info.isPlaying)
            }
            LockProgress(service: service, info: info)
            HStack(spacing: 0) {
                LockButton(symbol: lyricsOn ? "quote.bubble.fill" : "quote.bubble", size: 12, action: onLyrics)
                    .foregroundStyle(.white.opacity(lyricsOn ? 1 : 0.5))
                    .help(L("Songtext", "Lyrics"))
                Spacer(minLength: 0)
                LockButton(symbol: "backward.fill", size: 15) { service.send(.previous) }
                LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 21) { service.send(.togglePlayPause) }
                LockButton(symbol: "forward.fill", size: 15) { service.send(.next) }
                Spacer(minLength: 0)
                Image(systemName: output.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 36)
                    .help(output.deviceName)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
        .background {
            ZStack {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial).opacity(0.7)
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08), .white.opacity(0.3)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
                // Less transparency = a little shade behind the text.
                shape.fill(Color.black.opacity(solid * 0.3))
            }
            .animation(.easeInOut(duration: 0.25), value: solid)
        }
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
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
                    .frame(width: 30, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                    .frame(height: dragValue == nil ? 4 : 7)
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
                    .frame(width: 34, alignment: .trailing)
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
                .frame(width: 38, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}
