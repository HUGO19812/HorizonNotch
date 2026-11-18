import AppKit
import ScreenCaptureKit
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
    /// Kept for the screen saver; the clock over the large cover is now
    /// drawn on the lock screen too.
    var drawsClock = false
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
                    // The backdrop covers the system clock: draw our own,
                    // with the status row, where the system's would be.
                    GlassClock(screenHeight: size.height, tint: nowPlaying.artwork != nil ? nowPlaying.accent : nil)
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
        .animation(.easeInOut(duration: 0.4), value: settings.lockScreenBackdrop)
        .task(id: (nowPlaying.info?.artist ?? "") + "|" + (nowPlaying.info?.title ?? "")) {
            await hiRes.load(for: nowPlaying.info)
        }
    }

    /// Small glass card above "Touch ID or Enter Password".
    private func compact(info: NowPlayingInfo) -> some View {
        LiquidPlayerCard(service: nowPlaying, info: info, lyricsOn: false, overWallpaper: true,
                         onLyrics: { state.large = true; state.lyrics = true }) {
            CoverArt(image: nowPlaying.artwork, cornerRadius: 9)
                .matchedGeometryEffect(id: "cover", in: player)
                .frame(width: 56, height: 56)
                .onTapGesture { state.large = true }
                .help(L("Groß anzeigen", "Show large"))
        }
        .frame(width: 330)
        .transition(.opacity)
    }

    /// Large cover under the clock with the card below; with lyrics the
    /// pair moves left and the lyrics appear on the right.
    private func large(info: NowPlayingInfo, size: CGSize) -> some View {
        let cover = min(380, size.height * 0.3)
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
        // Below the clock and the status row.
        .padding(.top, size.height * 0.33)
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
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(appLocale)))
                    .font(.system(size: screenHeight * 0.027, weight: .semibold))
                    .foregroundStyle(glass)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: screenHeight * 0.145, weight: .semibold, design: .rounded))
                    .foregroundStyle(glass)
                    // Bright rim on top, a darker edge below: thick glass.
                    .overlay {
                        Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                            .font(.system(size: screenHeight * 0.145, weight: .semibold, design: .rounded))
                            .foregroundStyle(LinearGradient(colors: [.white.opacity(0.75), .clear, .clear, .white.opacity(0.25)],
                                                            startPoint: .top, endPoint: .bottom))
                            .blendMode(.plusLighter)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, screenHeight * 0.09)
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
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let crafted = overWallpaper && Wallpaper.shared.image != nil
        // Clear glass over the picture has no tint at all; the transparency
        // slider shades the other looks.
        let solid = crafted && settings.lockGlassStyle != .frosted
            ? 0 : 1 - min(max(settings.lockScreenTransparency, 0), 1)
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
                // Transparency slider: 100 % = perfectly clear glass, lower
                // values frost and shade it more and more.
                let frosted = settings.lockGlassStyle == .frosted
                if overWallpaper && Wallpaper.shared.image != nil {
                    CraftedGlass(shape: shape, frost: frosted ? 1 : 0)
                } else if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(frosted ? .regular : .clear, in: shape)
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
    private var loadedURL: URL?
    /// While locked, a photo of the screen itself (without our windows)
    /// replaces the desktop picture: it matches whatever the lock screen
    /// shows – any picture, Aerials, dynamic wallpapers.
    private var capturing = false
    private var captureTimer: Timer?

    func load(for screen: NSScreen) {
        if capturing { return }
        screenSize = screen.frame.size
        // macOS 26+ often reports a stale or default picture here; its
        // wallpaper store knows the one actually shown.
        guard let url = Self.storePictureURL(for: screen) ?? NSWorkspace.shared.desktopImageURL(for: screen)
        else { image = nil; cgImage = nil; return }
        if url == loadedURL, image != nil { return }
        loadedURL = url
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

    /// Photographs the lock screen now and every few seconds (moving
    /// wallpapers move on), until `endScreenCapture`. Needs the Screen
    /// Recording permission; without it the desktop picture stays.
    func beginScreenCapture(on screen: NSScreen) {
        guard CGPreflightScreenCaptureAccess() else { return }
        capturing = true
        capture(screen)
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.capture(screen)
        }
    }

    func endScreenCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        guard capturing else { return }
        capturing = false
        loadedURL = nil
    }

    private func capture(_ screen: NSScreen) {
        let displayID = screen.displayID
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                         configuration: configuration)
            else { return }
            await MainActor.run {
                guard let self, self.capturing else { return }
                let image = NSImage(cgImage: shot, size: size)
                guard !Self.isNearlyBlack(image) else { return }
                self.screenSize = size
                self.cgImage = shot
                self.image = image
            }
        }
    }

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
