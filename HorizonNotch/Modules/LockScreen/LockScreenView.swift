import AppKit
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
    @StateObject private var hiRes = HiResArtwork()
    @Namespace private var player

    private var spring: Animation { .spring(response: 0.5, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let info = nowPlaying.info, state.large {
                    Backdrop(image: settings.lockScreenBackdrop == .tinted ? nowPlaying.artwork
                                : (hiRes.image ?? nowPlaying.artwork),
                             tint: nowPlaying.accent, size: size,
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
        .task(id: (nowPlaying.info?.artist ?? "") + "|" + (nowPlaying.info?.title ?? "")) {
            await hiRes.load(for: nowPlaying.info)
        }
    }

    /// Small glass card above "Touch ID or Enter Password".
    private func compact(info: NowPlayingInfo) -> some View {
        LiquidPlayerCard(service: nowPlaying, info: info, lyricsOn: false, showsLyricsButton: false, overWallpaper: true,
                         onLyrics: { state.large = true; state.lyrics = true }) {
            CoverArt(image: nowPlaying.artwork, cornerRadius: 9)
                .matchedGeometryEffect(id: "cover", in: player)
                .frame(width: 56, height: 56)
                .onTapGesture { state.large = true }
                .help(L("Groß anzeigen", "Show large"))
        }
        .frame(width: 340)
        .transition(.opacity)
    }

    /// Large cover under the clock with the card below; with lyrics the
    /// pair moves left and the lyrics appear on the right.
    private func large(info: NowPlayingInfo, size: CGSize) -> some View {
        let cover = min(400, size.height * 0.37)
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
                    .frame(width: min(cover * 0.8, 320))
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
        .font(.system(size: max(16, screenHeight * 0.022), weight: .semibold))
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        let solid = 1 - min(max(settings.lockScreenTransparency, 0), 1)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                artwork
                VStack(alignment: Artwork.self == EmptyView.self ? .center : .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(info.artist.isEmpty ? (info.appName ?? "") : info.artist)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: Artwork.self == EmptyView.self ? .center : .leading)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .symbolEffect(.variableColor.iterative, isActive: info.isPlaying)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity, alignment: .top)
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
                if overWallpaper && Wallpaper.shared.image != nil {
                    CraftedGlass(shape: shape)
                } else if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial).opacity(0.4)
                    GlassRim(shape: shape)
                }
                if solid > 0 {
                    shape.fill(Color.black.opacity(solid * 0.25))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: solid)
        }
    }
}

/// Clear glass made by hand over the wallpaper piece behind the card.
private struct CraftedGlass: View {
    let shape: RoundedRectangle

    var body: some View {
        ZStack {
            // The wallpaper itself: the middle stays perfectly clear.
            WallpaperPiece()
                .clipShape(shape)
            // Lens: a magnified copy, only along the rim, bends the picture
            // at the edge the way thick glass does.
            WallpaperPiece(zoom: 1.18)
                .brightness(0.06)
                .clipShape(shape)
                .mask {
                    shape.strokeBorder(Color.white, lineWidth: 16)
                        .blur(radius: 7)
                }
            // A breath of light in the glass body, brighter at the top.
            shape.fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.0), .white.opacity(0.04)],
                                      startPoint: .top, endPoint: .bottom))
            GlassRim(shape: shape)
        }
        .compositingGroup()
    }
}

/// The bright specular edge with a faint blue/orange fringe.
private struct GlassRim: View {
    let shape: RoundedRectangle

    var body: some View {
        ZStack {
            shape.strokeBorder(AngularGradient(colors: [.blue.opacity(0.5), .clear, .orange.opacity(0.45), .clear,
                                                        .purple.opacity(0.4), .clear, .blue.opacity(0.5)],
                                               center: .center), lineWidth: 2)
                .blur(radius: 1.2)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15), .white.opacity(0.05),
                                                       .white.opacity(0.55)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1)
            shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 4)
                .blur(radius: 3)
        }
        .blendMode(.plusLighter)
    }
}

/// The part of the desktop picture that lies exactly behind this view
/// (the panel covers the whole screen, so window coordinates are screen
/// coordinates).
private struct WallpaperPiece: View {
    /// > 1 magnifies around the view's centre (the lens along the rim).
    var zoom: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            if let wallpaper = Wallpaper.shared.image {
                let frame = proxy.frame(in: .global)
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

/// The desktop picture of the island's screen, loaded once per lock.
final class Wallpaper {
    static let shared = Wallpaper()
    private(set) var image: NSImage?
    private(set) var screenSize: CGSize = .zero
    private var loadedURL: URL?

    func load(for screen: NSScreen) {
        screenSize = screen.frame.size
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { image = nil; return }
        if url == loadedURL, image != nil { return }
        loadedURL = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }
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

private struct LockButton: View {
    let symbol: String
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
/// and takes its artwork at 3000 px.
@MainActor
final class HiResArtwork: ObservableObject {
    @Published private(set) var image: NSImage?
    private var key = ""
    private static var cache: [String: NSImage] = [:]

    func load(for info: NowPlayingInfo?) async {
        guard let info, !info.title.isEmpty else { image = nil; return }
        let key = info.artist + "|" + info.title
        guard key != self.key else { return }
        self.key = key
        image = Self.cache[key]
        guard image == nil else { return }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: "\(info.artist) \(info.title)"),
                                 URLQueryItem(name: "entity", value: "song"),
                                 URLQueryItem(name: "limit", value: "5")]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return }
        // Same artist if possible, else the first hit.
        let artist = info.artist.lowercased()
        let hit = results.first { ($0["artistName"] as? String)?.lowercased().contains(artist.prefix(12)) == true }
            ?? results.first
        guard let small = hit?["artworkUrl100"] as? String,
              let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "3000x3000bb")),
              let (imageData, _) = try? await URLSession.shared.data(from: big),
              let loaded = NSImage(data: imageData), key == self.key else { return }
        Self.cache[key] = loaded
        image = loaded
    }
}
