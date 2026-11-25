import AppKit
import EventKit
import OpenDirectory
import SwiftUI

/// What the lock screen player shows; back to the chosen start view
/// (Settings → Lock Screen) on every lock.
final class LockScreenState: ObservableObject {
    /// Large cover below the clock instead of the small card.
    @Published var large = false
    /// Lyrics beside the large cover.
    @Published var lyrics = false
    /// Lyrics over the lock screen's own picture, with the small player.
    @Published var miniLyrics = false

    func reset() {
        miniLyrics = false
        let start = AppSettings.shared.lockScreenStart
        large = start != .compact
        lyrics = start == .lyrics
    }
}

/// Data the lock screen shows besides the music (set by the app delegate).
enum LockScreenSources {
    static weak var weather: WeatherService?
    static weak var calendar: CalendarModule?
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
    /// Kept for the screen saver; the clock over the large cover is now
    /// drawn on the lock screen too.
    var drawsClock = false
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var hiRes = HiResArtwork()
    /// Apple Music's moving cover for the large player; kept across the
    /// small and large player within one lock.
    @StateObject private var motion = MotionArtwork()
    @Namespace private var player
    /// When the lock screen appeared: right after it, a song turning out to
    /// have no lyrics switches to the cover without a visible move.
    @State private var shownAt = Date()

    private var spring: Animation { .spring(response: 0.5, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let info = nowPlaying.info, state.large, settings.lockScreenSpicyLyrics {
                    // Large cover, with or without lyrics: one view, so the
                    // lyrics slide in instead of the screen being swapped.
                    SpicyLockScreen(nowPlaying: nowPlaying, lyrics: lyrics, motion: motion, info: info, size: size,
                                    artwork: settings.lockScreenBackdrop == .tinted ? nil : hiRes.image,
                                    showLyrics: state.lyrics && lyricsAvailable, lyricsAvailable: lyricsAvailable,
                                    namespace: player,
                                    toggleLyrics: { state.lyrics = !(state.lyrics && lyricsAvailable) },
                                    minimize: { state.large = false; state.lyrics = false })
                    .transition(.opacity)
                    LockClock(size: size, tint: settings.lockClockTint && nowPlaying.artwork != nil ? nowPlaying.accent : nil)
                        .transition(.opacity)
                } else if let info = nowPlaying.info, state.large {
                    Backdrop(image: settings.lockScreenBackdrop == .tinted ? nowPlaying.artwork
                                : (hiRes.image ?? nowPlaying.artwork),
                             tint: nowPlaying.accent, size: size,
                             style: settings.lockScreenBackdrop)
                        .transition(.opacity)
                    // The backdrop covers the system clock: the same clock,
                    // with the status row, exactly where the system's is.
                    LockClock(size: size, tint: settings.lockClockTint && nowPlaying.artwork != nil ? nowPlaying.accent : nil)
                        .transition(.opacity)
                    if settings.lockScreenStatusRow {
                        StatusRow(screenHeight: size.height)
                            .position(x: size.width / 2, y: size.height * 0.285)
                            .transition(.opacity)
                    }
                    large(info: info, size: size)
                } else {
                    if settings.lockScreenStatusRow {
                        // Just below the system clock.
                        StatusRow(screenHeight: size.height)
                            .position(x: size.width / 2, y: size.height * 0.285)
                            .transition(.opacity)
                    }
                    if let info = nowPlaying.info {
                        if state.miniLyrics {
                            // Over the wallpaper, between the widgets and the card.
                            let top = size.height * 0.285 + 40
                            let bottom = size.height * 0.705 - 110
                            LyricsPanel(lyrics: lyrics, info: info, large: true, fontSize: 28) { nowPlaying.seek(to: $0) }
                                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                                .frame(width: min(640, size.width * 0.5), height: max(160, bottom - top))
                                .position(x: size.width / 2, y: (top + bottom) / 2)
                                .transition(.opacity)
                        }
                        compact(info: info)
                            .position(x: size.width / 2, y: size.height * 0.705)
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
        .animation(Date().timeIntervalSince(shownAt) < 2 ? nil : spring, value: lyricsAvailable)
        .animation(spring, value: state.miniLyrics)
        .animation(.easeInOut(duration: 0.4), value: settings.lockScreenBackdrop)
        .task(id: (nowPlaying.info?.artist ?? "") + "|" + (nowPlaying.info?.title ?? "") + "|"
                  + String(nowPlaying.info?.artworkID ?? 0)) {
            // Wait for the player's own artwork: it decides whether a hi-res
            // hit is the same cover.
            if nowPlaying.info?.artworkID != 0 && nowPlaying.artwork == nil { return }
            await hiRes.load(for: nowPlaying.info, artwork: nowPlaying.artwork)
        }
        // While locked: the lyrics (LRCLIB, cached), so the large player
        // knows whether there are any – without them it shows only the
        // cover, even when "cover and lyrics" is the start view.
        .task(id: (nowPlaying.info?.artist ?? "") + "|" + (nowPlaying.info?.title ?? "")) {
            guard settings.lockScreenSpicyLyrics, let info = nowPlaying.info else { return }
            lyrics.load(for: info)
        }
        // The moving cover is looked up as soon as the lock screen shows
        // (then remembered for the session) and buffered once the player is
        // large, so it is ready when it is needed.
        .task(id: (nowPlaying.info?.artist ?? "") + "|" + (nowPlaying.info?.title ?? "") + (state.large ? "|large" : "")) {
            guard settings.lockScreenSpicyLyrics else { return }
            await motion.load(for: nowPlaying.info)
            if state.large { motion.prepare() }
        }
    }

    /// Not known to be without lyrics (still loading counts as available).
    private var lyricsAvailable: Bool { lyrics.state != .unavailable }

    /// Small glass card above "Touch ID or Enter Password".
    private func compact(info: NowPlayingInfo) -> some View {
        LiquidPlayerCard(service: nowPlaying, info: info, lyricsOn: state.miniLyrics, overWallpaper: true,
                         onLyrics: { state.miniLyrics.toggle() }) {
            CoverArt(image: nowPlaying.artwork, cornerRadius: 9)
                .matchedGeometryEffect(id: "cover", in: player)
                .frame(width: 56, height: 56)
                .onTapGesture { state.miniLyrics = false; state.large = true }
                .help(L("Groß anzeigen", "Show large"))
        }
        .frame(width: 330)
        .transition(.opacity)
    }

    /// Large cover between the status row and the player; the player is
    /// the very same card at the very same place as without the cover.
    /// With lyrics, cover and card move left and the lyrics appear right.
    private func large(info: NowPlayingInfo, size: CGSize) -> some View {
        let cardY = size.height * 0.705
        let top = size.height * 0.285 + 34
        let cover = min(380, cardY - 74 - top - 24)
        // With lyrics, cover + card and the lyrics sit side by side as one
        // centred pair with a small gap.
        let column = max(cover, 330)
        let lyricsWidth = min(540, size.width * 0.36)
        let gap: CGFloat = 56
        let pairLeft = (size.width - column - gap - lyricsWidth) / 2
        let columnX = state.lyrics ? pairLeft + column / 2 : size.width / 2
        return ZStack {
            CoverArt(image: nowPlaying.artwork, cornerRadius: 10)
                .matchedGeometryEffect(id: "cover", in: player)
                .frame(width: cover, height: cover)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .onTapGesture { state.large = false; state.lyrics = false }
                .help(L("Klein anzeigen", "Show small"))
                .position(x: columnX, y: top + (cardY - 74 - top) / 2)
            // The large cover is right above: no small one in the card.
            LiquidPlayerCard(service: nowPlaying, info: info, lyricsOn: state.lyrics,
                             onLyrics: { state.lyrics.toggle() }) { EmptyView() }
                .frame(width: 330)
                .position(x: columnX, y: cardY)
                .transition(.opacity)
            if state.lyrics {
                LyricsPanel(lyrics: lyrics, info: info, large: true, fontSize: 30) { nowPlaying.seek(to: $0) }
                    .frame(width: lyricsWidth, height: cardY + 60 - top)
                    .position(x: pairLeft + column + gap + lyricsWidth / 2, y: top + (cardY + 60 - top) / 2)
                    .transition(.opacity.combined(with: .offset(x: 40)))
            }
        }
        .frame(width: size.width, height: size.height)
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

/// The clock over the large cover, where and how macOS draws its own:
/// LoginUIKit's real date and time views; tinted by the cover (a setting)
/// or without LoginUIKit, a glass copy in the same font, size and place.
struct LockClock: View {
    let size: CGSize
    let tint: Color?

    // Where macOS puts them, as a share of the screen height.
    private var dateY: CGFloat { size.height * 0.1066 }
    private var timeY: CGFloat { size.height * 0.186 }

    var body: some View {
        TimelineView(.everyMinute) { context in
            ZStack {
                if tint == nil, SystemClock.isAvailable {
                    SystemClockView(part: .date, minute: context.date)
                        .frame(width: 600, height: 60)
                        .position(x: size.width / 2, y: dateY)
                    SystemClockView(part: .time, minute: context.date)
                        .frame(width: 900, height: 240)
                        .position(x: size.width / 2, y: timeY)
                } else {
                    Text(Self.dateFormatter.string(from: context.date))
                        .font(.system(size: 31.28 * size.height / 1117, weight: .medium))
                        .foregroundStyle(glass)
                        .position(x: size.width / 2, y: dateY)
                    Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                        .font(timeFont)
                        .foregroundStyle(glass)
                        .overlay {
                            Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                                .font(timeFont)
                                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.75), .clear, .clear, .white.opacity(0.25)],
                                                                startPoint: .top, endPoint: .bottom))
                                .blendMode(.plusLighter)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        .position(x: size.width / 2, y: timeY)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private var timeFont: Font {
        let points = 156.38 * size.height / 1117
        if let system = SystemClock.timeFont, let scaled = NSFont(descriptor: system.fontDescriptor, size: points) {
            return Font(scaled)
        }
        return .system(size: points, weight: .semibold, design: .rounded)
    }

    private var glass: LinearGradient {
        let base = tint ?? Color(white: 0.6)
        return LinearGradient(colors: [.white.opacity(0.9), base.opacity(0.85), base.opacity(0.6)],
                              startPoint: .top, endPoint: .bottom)
    }
}

/// The widgets under the clock, as chosen in Settings → Lock Screen:
/// weather, battery (the iOS 27 battery with the level inside),
/// headphones and the next appointment, in one row.
private struct StatusRow: View {
    let screenHeight: CGFloat
    @ObservedObject private var power = PowerSource.shared
    @ObservedObject private var output = AudioOutput.shared
    @ObservedObject private var settings = AppSettings.shared

    private var fontSize: CGFloat { max(16, screenHeight * 0.022) }

    var body: some View {
        HStack(spacing: 22) {
            if settings.lockWidgetWeather, let report = LockScreenSources.weather?.report {
                item(WeatherCode.symbol(report.code, isDay: report.isDay), "\(Int(report.temperature.rounded()))°")
            }
            if settings.lockWidgetBattery, power.state.hasBattery {
                HStack(spacing: 4) {
                    PhoneBattery(percent: power.state.percent, showNumber: true,
                                 fill: power.state.isLowPower ? .yellow
                                     : (power.state.isPluggedIn ? .green : (power.state.percent <= 20 ? .red : .white)))
                        .scaleEffect(fontSize / 13, anchor: .center)
                        .frame(width: 29 * fontSize / 13, height: 13 * fontSize / 13)
                    if power.state.isCharging || power.state.isPluggedIn {
                        Image(systemName: "bolt.fill").font(.system(size: fontSize * 0.6, weight: .bold))
                    }
                }
            }
            if settings.lockWidgetHeadphones, output.isBluetooth {
                item(output.symbol, nil)
            }
            if settings.lockWidgetEvent, let event = LockScreenSources.calendar?.nextEvent,
               Calendar.current.isDateInToday(event.startDate) {
                item("calendar", event.startDate.formatted(.dateTime.hour().minute().locale(appLocale))
                     + " " + (event.title ?? ""))
                    .lineLimit(1)
                    .frame(maxWidth: 320)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
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

/// The player card, like Canopy's: cover, title and artist, a faint
/// waveform at the top right, a thin progress line with both times, the
/// three buttons in the middle and the headphones on the right.
///
/// The glass is hand-made like Canopy's (system glass cannot see the lock
/// screen's wallpaper, which belongs to another process): the matching
/// piece of the desktop picture lies behind the card, a slightly magnified
/// copy along the rim bends it like a lens, and a bright specular edge with
/// a hint of colour fringe outlines it. Nothing darkens the middle.
private struct LiquidPlayerCard<Artwork: View>: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject private var output = AudioOutput.shared
    @ObservedObject private var settings = AppSettings.shared
    let info: NowPlayingInfo
    let lyricsOn: Bool
    var showsLyricsButton = true
    /// Over the lock screen's own wallpaper (the small card); the large
    /// view draws its own backdrop.
    var overWallpaper = false
    let onLyrics: () -> Void
    @ViewBuilder var artwork: Artwork

    private static var systemGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let crafted = overWallpaper && Wallpaper.shared.image != nil
        // Clear glass over the picture has no tint at all; the transparency
        // slider shades the other looks.
        // Over our own cover backdrop the system's clear Liquid Glass sees
        // the picture, so it needs no shade either.
        let solid = (crafted && settings.lockGlassStyle != .frosted) || (!overWallpaper && Self.systemGlass)
            ? 0 : 1 - min(max(settings.lockScreenTransparency, 0), 1)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                artwork
                VStack(alignment: Artwork.self == EmptyView.self ? .center : .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(Artwork.self == EmptyView.self ? .center : .leading)
                    Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: Artwork.self == EmptyView.self ? .center : .leading)
                if Artwork.self != EmptyView.self {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .symbolEffect(.variableColor.iterative, isActive: info.isPlaying)
                        .frame(width: 26)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            LockProgress(service: service, info: info)
                .padding(.top, 14)
            HStack(spacing: 0) {
                Group {
                    if showsLyricsButton {
                        LockButton(symbol: lyricsOn ? "quote.bubble.fill" : "quote.bubble", size: 13, action: onLyrics)
                            .foregroundStyle(.white.opacity(lyricsOn ? 1 : 0.55))
                            .help(L("Songtext", "Lyrics"))
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
                .frame(width: 34, height: 34)
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    LockButton(symbol: "backward.fill", size: 16) { service.send(.previous) }
                    LockButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 25) { service.send(.togglePlayPause) }
                    LockButton(symbol: "forward.fill", size: 16) { service.send(.next) }
                }
                Spacer(minLength: 0)
                Image(systemName: output.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .help(output.deviceName)
            }
            .padding(.top, 10)
        }
        .foregroundStyle(.white)
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
        // A whisper of shadow keeps text readable on bright wallpapers.
        .shadow(color: .black.opacity(0.18 + solid * 0.25), radius: 1.5, y: 0.5)
        .background {
            ZStack {
                // Transparency slider: 100 % = perfectly clear glass, lower
                // values frost and shade it more and more.
                let frosted = settings.lockGlassStyle == .frosted
                if overWallpaper && Wallpaper.shared.image != nil {
                    CraftedGlass(shape: shape, frost: frosted ? 1 : 0)
                } else if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(overWallpaper && frosted ? .regular : .clear, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial).opacity(0.3 + solid * 0.7)
                }
                // 100 % = nothing on top, as clean as Canopy's; lower values
                // shade it into dark smoked glass.
                if solid > 0 {
                    shape.fill(Color.black.opacity(solid * 0.55))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: solid)
        }
    }
}

/// Glass made by hand over the wallpaper behind the card, in two looks:
/// - clear: real Liquid Glass, sharp in the middle and refracting along a
///   convex rim (see LiquidGlassView);
/// - frosted: the picture is blurred and lightened, with a soft diagonal
///   sheen across the glass and a light rim.
private struct CraftedGlass: View {
    let shape: RoundedRectangle
    /// 0 = clear, 1 = frosted.
    var frost: Double = 0

    var body: some View {
        if frost > 0.5 {
            frosted.compositingGroup()
        } else {
            // Real refraction along a convex rim, sharp in the middle.
            LiquidGlassView(cornerRadius: shape.cornerSize.width)
        }
    }

    /// Like Canopy's frosted card: the picture still recognisable but soft,
    /// a light grey veil, a bright beam of light falling diagonally across
    /// the glass from the upper right, and a soft light rim.
    private var frosted: some View {
        ZStack {
            WallpaperPiece()
                .blur(radius: 11)
            shape.fill(Color.white.opacity(0.09))
            // The beam: a wide soft band of light, tilted.
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .white.opacity(0.32), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.42, height: h * 2.2)
                    .rotationEffect(.degrees(32))
                    .position(x: w * 0.6, y: h * 0.5)
                    .blur(radius: 14)
            }
            .blendMode(.plusLighter)
            // Light gathering along the top and right edges.
            shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 6)
                .blur(radius: 6)
                .blendMode(.plusLighter)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.12), .white.opacity(0.3)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .clipShape(shape)
    }

}

/// The part of the desktop picture that lies exactly behind this view
/// (the panel covers the whole screen, so window coordinates are screen
/// coordinates).
struct WallpaperPiece: View {
    /// > 1 magnifies around the view's centre (the lens along the rim).
    var zoom: CGFloat = 1
    /// Where the window's top-left corner sits on the screen (the island
    /// panel does not cover the whole screen like the lock screen does).
    var windowOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            if let wallpaper = Wallpaper.shared.image {
                let frame = proxy.frame(in: .global).offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
                let screen = Wallpaper.shared.screenSize
                Image(nsImage: wallpaper)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: screen.width, height: screen.height)
                    .clipped()
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: screen.width * zoom, height: screen.height * zoom, alignment: .topLeading)
                    .offset(x: frame.width / 2 - zoom * (frame.minX + frame.width / 2),
                            y: frame.height / 2 - zoom * (frame.minY + frame.height / 2))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The desktop picture of the island's screen. Both the lock screen card
/// and the glass island lay the matching piece of it behind their glass.
/// Moving wallpapers (Aerials) only give a black placeholder file; those
/// count as "no picture" so the system glass is used instead.
final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()
    @Published private(set) var image: NSImage?
    /// The same picture decoded once, for the refracting glass.
    private(set) var cgImage: CGImage?
    private(set) var screenSize: CGSize = .zero
    /// The lock screen's picture moves (Sequoia, Aerials, dynamic …): its
    /// still file shows only one moment of it, so nothing may be bent from
    /// that still – it would show pieces of another picture.
    @Published private(set) var isLive = false
    /// The file and its modification date, to notice when it changes.
    private var loadedKey: String?

    func load(for screen: NSScreen) {
        screenSize = screen.frame.size
        let live = Self.lockScreenIsLive
        if live != isLive { isLive = live }
        // The lock screen's own picture first: macOS keeps it as a file for
        // the login window (also a still of Aerials and dynamic wallpapers,
        // and it can differ from the desktop). Then the desktop picture –
        // macOS 26+ often reports a stale one, its wallpaper store knows the
        // one actually shown.
        guard let url = Self.lockScreenPictureURL ?? Self.storePictureURL(for: screen)
                ?? NSWorkspace.shared.desktopImageURL(for: screen)
        else { image = nil; cgImage = nil; return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = url.path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        if key == loadedKey, image != nil { return }
        loadedKey = key
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
           let loaded = NSImage(contentsOf: url), !Self.isNearlyBlack(loaded) {
            cgImage = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil)
            image = loaded
        } else {
            cgImage = nil
            image = nil
        }
    }

    /// /var/db/Wallpapers/<user's generated UID>/Wallpaper.png, readable by
    /// everyone and kept up to date by macOS.
    private static var lockScreenPictureURL: URL? {
        guard let uid = generatedUID else { return nil }
        let url = URL(fileURLWithPath: "/var/db/Wallpapers/\(uid)/Wallpaper.png")
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Read from the login window's own record of the lock screen picture:
    /// only a plain picture ("….image") stands still.
    private static var lockScreenIsLive: Bool {
        guard let uid = generatedUID,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/var/db/Wallpapers/\(uid)/Metadata.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let content = plist["Content"] as? [String: Any],
              let provider = (content["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
        else { return false }
        return !provider.hasSuffix(".image")
    }

    static let generatedUID: String? = {
        guard let node = try? ODNode(session: .default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                            attributes: [kODAttributeTypeGUID]),
              let values = try? record.values(forAttribute: kODAttributeTypeGUID)
        else { return nil }
        return values.first as? String
    }()

    /// The desktop picture from macOS's wallpaper store: of all the places
    /// a picture can be set (all spaces, a display, one space on a display)
    /// the one that was shown last on this display wins. Only plain picture
    /// files; moving or system-provided ones fall back to the reported URL.
    private static func storePictureURL(for screen: NSScreen) -> URL? {
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let displayUUID = CGDisplayCreateUUIDFromDisplayID(screen.displayID)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }

        var best: (date: Date, url: URL?)?
        func visit(_ node: [String: Any], path: String) {
            if let desktop = node["Desktop"] as? [String: Any] {
                // Entries for another display do not count.
                let otherDisplay = path.contains("/Displays/") && !(displayUUID.map { path.contains($0) } ?? true)
                let date = (desktop["LastUse"] as? Date) ?? (desktop["LastSet"] as? Date) ?? .distantPast
                if !otherDisplay, date > (best?.date ?? .distantPast) {
                    best = (date, pictureURL(in: desktop))
                }
            }
            for (key, value) in node {
                if let child = value as? [String: Any] { visit(child, path: path + "/" + key) }
            }
        }
        visit(store, path: "")
        return best?.url
    }

    private static func pictureURL(in desktop: [String: Any]) -> URL? {
        guard let content = desktop["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              (choice["Provider"] as? String)?.hasSuffix(".image") == true,
              let configuration = choice["Configuration"] as? Data,
              let settings = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
              let url = settings["url"] as? [String: Any],
              let relative = url["relative"] as? String
        else { return nil }
        return URL(string: relative)
    }

    static func isNearlyBlack(_ image: NSImage) -> Bool {
        var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return true }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let context = CGContext(data: &pixels, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        // Only a truly black placeholder; dark pictures (space, night) count.
        return Double(total) / Double(16 * 16 * 3) < 2.5
    }

    /// One of Apple's own desktop pictures (for the settings preview).
    static let applePicture: NSImage? = {
        let root = "/System/Library/Desktop Pictures"
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return nil }
        var files: [String] = []
        for case let path as String in enumerator {
            let lower = path.lowercased()
            if (lower.hasSuffix(".heic") || lower.hasSuffix(".jpg") || lower.hasSuffix(".png")) && !lower.contains("thumbnail") {
                files.append(path)
            }
        }
        let preferred = ["tahoe", "sequoia", "sonoma", "ventura", "monterey", "big sur"]
        let sorted = files.sorted { a, b in
            let ra = preferred.firstIndex { a.lowercased().contains($0) } ?? 99
            let rb = preferred.firstIndex { b.lowercased().contains($0) } ?? 99
            return ra != rb ? ra < rb : a < b
        }
        for file in sorted {
            if let image = NSImage(contentsOfFile: root + "/" + file), !isNearlyBlack(image) { return image }
        }
        return nil
    }()
}

/// Draggable progress bar with elapsed time left and remaining time right.
struct LockProgress: View {
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
                    .frame(width: 36, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: proxy.size.width * CGFloat(fraction))
                    }
                    .frame(height: dragValue == nil ? 3.5 : 7)
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
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LockButton: View {
    let symbol: String
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        // The action runs a moment later: a change made right inside a
        // button's action moves the clicked button straight to its end
        // position instead of along with the others.
        Button(action: { DispatchQueue.main.async(execute: action) }) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The cover in high resolution for the full-screen backdrop: the player
/// only hands over a small thumbnail (often 300 px), which turns to mush
/// when stretched over the screen. Looks the song up in the iTunes catalogue
/// and takes its artwork at 3000 px – but only when it is really the same
/// cover: artist and title must match, and the picture must look like the
/// player's own artwork. Otherwise the player's artwork is used.
@MainActor
final class HiResArtwork: ObservableObject {
    @Published private(set) var image: NSImage?
    private var key = ""
    private static var cache: [String: NSImage] = [:]

    func load(for info: NowPlayingInfo?, artwork: NSImage?) async {
        guard let info, !info.title.isEmpty else { image = nil; key = ""; return }
        let key = info.artist + "|" + info.title
        guard key != self.key else { return }
        self.key = key
        image = Self.cache[key]
        guard image == nil else { return }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: "\(info.artist) \(Self.normalized(info.title))"),
                                 URLQueryItem(name: "entity", value: "song"),
                                 URLQueryItem(name: "limit", value: "10")]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return }
        let artist = Self.normalized(info.artist), title = Self.normalized(info.title)
        let hits = results.filter { result in
            let hitArtist = Self.normalized(result["artistName"] as? String ?? "")
            let hitTitle = Self.normalized(result["trackName"] as? String ?? "")
            let artistMatches = !artist.isEmpty && (hitArtist.contains(artist) || artist.contains(hitArtist)) && !hitArtist.isEmpty
            return artistMatches && hitTitle == title
        }
        for hit in hits.prefix(3) {
            guard let small = hit["artworkUrl100"] as? String,
                  let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "3000x3000bb")),
                  let (imageData, _) = try? await URLSession.shared.data(from: big),
                  let loaded = NSImage(data: imageData), key == self.key else { continue }
            // Same song on another release can carry another cover.
            if let artwork, !Self.looksAlike(loaded, artwork) { continue }
            Self.cache[key] = loaded
            image = loaded
            return
        }
    }

    /// Lowercased, without "(feat. …)", "- Radio Edit", punctuation.
    static func normalized(_ text: String) -> String {
        var value = text.lowercased()
        for separator in [" (", " [", " - ", " feat.", " ft."] {
            if let range = value.range(of: separator) { value = String(value[..<range.lowerBound]) }
        }
        return value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Compares both covers at 8 × 8 pixels: the mean colour difference must
    /// stay small.
    static func looksAlike(_ a: NSImage, _ b: NSImage) -> Bool {
        guard let pa = pixels(a), let pb = pixels(b) else { return true }
        var total = 0
        for i in 0..<pa.count { total += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(total) / Double(pa.count) < 38
    }

    private static func pixels(_ image: NSImage) -> [UInt8]? {
        let side = 8
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var rgb: [UInt8] = []
        rgb.reserveCapacity(side * side * 3)
        for i in stride(from: 0, to: data.count, by: 4) {
            rgb.append(data[i])
            rgb.append(data[i + 1])
            rgb.append(data[i + 2])
        }
        return rgb
    }
}

/// The lock screen in small at the top of its settings page: the desktop
/// picture (or one of Apple's), the time large, and the player card in the
/// chosen glass, frosted or clear – it changes as you pick.
struct LockScreenPreview: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var wallpaper = Wallpaper.shared

    private var picture: NSImage? { wallpaper.image ?? Wallpaper.applePicture }

    var body: some View {
        let frosted = settings.lockGlassStyle == .frosted
        let solid = 1 - min(max(settings.lockScreenTransparency, 0), 1)
        let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            backdrop
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .offset(y: -50)
            // The card: the same picture behind it, clear or frosted.
            backdrop
                .blur(radius: frosted ? 14 : 0)
                .overlay(Color.white.opacity(frosted ? 0.08 : 0))
                .overlay(Color.black.opacity(solid * 0.55))
                .mask(card.frame(width: 200, height: 88).offset(y: 50))
            card
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.35)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                .frame(width: 200, height: 88)
                .offset(y: 50)
            cardContent
                .frame(width: 200, height: 88)
                .offset(y: 50)
        }
        .frame(height: 290)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: frosted)
        .animation(.easeInOut(duration: 0.2), value: solid)
        .onAppear {
            if let screen = NSScreen.islandScreen(preferred: settings.displayID) { wallpaper.load(for: screen) }
        }
    }

    private var backdrop: some View {
        Color.clear
            .overlay {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.1, green: 0.15, blue: 0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipped()
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.35)).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Titel", "Title")).font(.system(size: 10, weight: .semibold))
                    Text(L("Interpret", "Artist")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            Capsule().fill(Color.white.opacity(0.3)).frame(height: 2.5)
                .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 50, height: 2.5) }
            HStack(spacing: 20) {
                Image(systemName: "backward.fill")
                Image(systemName: "pause.fill").font(.system(size: 13))
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 9))
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        .padding(10)
    }
}
