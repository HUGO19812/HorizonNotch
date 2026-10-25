import AppKit
import SwiftUI
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en
    var id: String { rawValue }
}

/// How the shelf sends files: the small square next to the shelf.
enum ShareService: String, CaseIterable, Identifiable {
    case airdrop, mail, messages
    var id: String { rawValue }
}

enum SneakPeekStyle: String, CaseIterable, Identifiable {
    /// A line with the song below the notch.
    case standard
    /// Title and artist in the widened wings beside the notch.
    case inline
    var id: String { rawValue }
}

/// What a sideways swipe on the music tab does.
enum MusicGesture: String, CaseIterable, Identifiable {
    case off, track, seek
    var id: String { rawValue }
}

/// Which tab the island shows when it opens.
enum OpenPageBehavior: String, CaseIterable, Identifiable {
    case first, last
    var id: String { rawValue }
}

/// Where the volume/brightness overlay appears.
enum HUDStyle: String, CaseIterable, Identifiable {
    /// Inside the island next to the notch.
    case notch
    /// A slim vertical bar at the left edge of the screen.
    case sideBar
    var id: String { rawValue }
}

/// Colour of the volume/brightness/keyboard bar.
enum HUDBarColor: String, CaseIterable, Identifiable {
    case white
    /// Volume in the accent colour, brightness yellow, keyboard light blue.
    case colorful
    var id: String { rawValue }
}

/// What the lock screen player shows first after locking.
enum LockScreenStart: String, CaseIterable, Identifiable {
    /// The small glass card.
    case compact
    /// Large cover under the clock.
    case cover
    /// Large cover and the lyrics beside it.
    case lyrics
    var id: String { rawValue }
}

/// Colour of the sung lyrics.
enum LyricsColorMode: String, CaseIterable, Identifiable {
    /// White on grey, like Apple Music.
    case music
    case cover
    case fixed
    var id: String { rawValue }
}

enum IslandAppearance: String, CaseIterable, Identifiable {
    case black, glass
    /// Solid fill in a colour of your choice.
    case tinted
    var id: String { rawValue }
}

/// All user preferences. Every property is written to UserDefaults on change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var appearance: IslandAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Seconds the pointer has to rest on the island before it opens.
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    /// 1 = default; higher is faster.
    @Published var animationSpeed: Double { didSet { defaults.set(animationSpeed, forKey: "animationSpeed") } }
    /// 0 = automatic (built-in display with notch, else main display).
    @Published var displayID: UInt32 { didSet { defaults.set(Int(displayID), forKey: "displayID") } }
    @Published var replaceSystemHUD: Bool { didSet { defaults.set(replaceSystemHUD, forKey: "replaceSystemHUD") } }
    @Published var showVisualizer: Bool { didSet { defaults.set(showVisualizer, forKey: "showVisualizer") } }
    @Published var moduleOrder: [String] { didSet { defaults.set(moduleOrder, forKey: "moduleOrder") } }
    @Published var disabledModules: Set<String> { didSet { defaults.set(Array(disabledModules), forKey: "disabledModules") } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var weatherUsesLocation: Bool { didSet { defaults.set(weatherUsesLocation, forKey: "weatherUsesLocation") } }
    @Published var weatherCity: String { didSet { defaults.set(weatherCity, forKey: "weatherCity") } }
    /// Coordinates of the place picked from the search; nil = look up weatherCity by name.
    @Published var weatherCoordinate: [Double]? { didSet { defaults.set(weatherCoordinate, forKey: "weatherCoordinate") } }
    @Published var useFahrenheit: Bool { didSet { defaults.set(useFahrenheit, forKey: "useFahrenheit") } }
    @Published var showLyrics: Bool { didSet { defaults.set(showLyrics, forKey: "showLyrics") } }
    @Published var connectivityAllBluetooth: Bool { didSet { defaults.set(connectivityAllBluetooth, forKey: "connectivityAllBluetooth") } }
    @Published var connectivityFocus: Bool { didSet { defaults.set(connectivityFocus, forKey: "connectivityFocus") } }
    @Published var notifyDownloads: Bool { didSet { defaults.set(notifyDownloads, forKey: "notifyDownloads") } }
    @Published var lockScreenWidgets: Bool { didSet { defaults.set(lockScreenWidgets, forKey: "lockScreenWidgets") } }
    @Published var lockScreenStart: LockScreenStart { didSet { defaults.set(lockScreenStart.rawValue, forKey: "lockScreenStart") } }
    /// Hide the island while another app or a video fills the screen.
    @Published var hideInFullscreen: Bool { didSet { defaults.set(hideInFullscreen, forKey: "hideInFullscreen") } }
    /// The large lock screen player as a screen saver while music plays.
    @Published var screenSaverEnabled: Bool { didSet { defaults.set(screenSaverEnabled, forKey: "screenSaverEnabled") } }
    /// Idle minutes before it starts.
    @Published var screenSaverDelay: Double { didSet { defaults.set(screenSaverDelay, forKey: "screenSaverDelay") } }
    @Published var screenSaverLyrics: Bool { didSet { defaults.set(screenSaverLyrics, forKey: "screenSaverLyrics") } }
    /// Look for a new release on GitHub after launch and every six hours.
    @Published var autoUpdateCheck: Bool { didSet { defaults.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    @Published var sneakPeek: Bool { didSet { defaults.set(sneakPeek, forKey: "sneakPeek") } }
    @Published var sneakPeekOnSeek: Bool { didSet { defaults.set(sneakPeekOnSeek, forKey: "sneakPeekOnSeek") } }
    @Published var sneakPeekDuration: Double { didSet { defaults.set(sneakPeekDuration, forKey: "sneakPeekDuration") } }
    @Published var sneakPeekStyle: SneakPeekStyle { didSet { defaults.set(sneakPeekStyle.rawValue, forKey: "sneakPeekStyle") } }
    /// Trackpad click when a date strip (calendar, weather) snaps to a day.
    @Published var scrollHaptics: Bool { didSet { defaults.set(scrollHaptics, forKey: "scrollHaptics") } }
    /// 1 (barely noticeable) … TrackpadHaptics.levels (strongest).
    @Published var hapticLevel: Int { didSet { defaults.set(hapticLevel, forKey: "hapticLevel") } }
    @Published var openPage: OpenPageBehavior { didSet { defaults.set(openPage.rawValue, forKey: "openPage") } }
    @Published var hiddenTabs: Set<String> { didSet { defaults.set(Array(hiddenTabs), forKey: "hiddenTabs") } }
    @Published var hudShowPercent: Bool { didSet { defaults.set(hudShowPercent, forKey: "hudShowPercent") } }
    @Published var hudStyle: HUDStyle { didSet { defaults.set(hudStyle.rawValue, forKey: "hudStyle") } }
    @Published var hudBarColor: HUDBarColor { didSet { defaults.set(hudBarColor.rawValue, forKey: "hudBarColor") } }
    @Published var musicGesture: MusicGesture { didSet { defaults.set(musicGesture.rawValue, forKey: "musicGesture") } }
    @Published var keepAwakeIcon: Bool { didSet { defaults.set(keepAwakeIcon, forKey: "keepAwakeIcon") } }
    /// Stay awake switches itself off after this many hours; 0 = no limit.
    @Published var keepAwakeLimitHours: Int { didSet { defaults.set(keepAwakeLimitHours, forKey: "keepAwakeLimitHours") } }
    @Published var batteryInHeader: Bool { didSet { defaults.set(batteryInHeader, forKey: "batteryInHeader") } }
    @Published var batteryShowPercent: Bool { didSet { defaults.set(batteryShowPercent, forKey: "batteryShowPercent") } }
    @Published var showSource: Bool { didSet { defaults.set(showSource, forKey: "showSource") } }
    @Published var lyricsColorMode: LyricsColorMode { didSet { defaults.set(lyricsColorMode.rawValue, forKey: "lyricsColorMode") } }
    @Published var lyricsFixedColor: String { didSet { defaults.set(lyricsFixedColor, forKey: "lyricsFixedColor") } }
    @Published var albumTint: Bool { didSet { defaults.set(albumTint, forKey: "albumTint") } }
    @Published var lyricsLarge: Bool { didSet { defaults.set(lyricsLarge, forKey: "lyricsLarge") } }
    @Published var shareService: ShareService { didSet { defaults.set(shareService.rawValue, forKey: "shareService") } }
    @Published var calendarDaysAhead: Int { didSet { defaults.set(calendarDaysAhead, forKey: "calendarDaysAhead") } }
    @Published var calendarShowAllDay: Bool { didSet { defaults.set(calendarShowAllDay, forKey: "calendarShowAllDay") } }
    @Published var calendarCountdown: Bool { didSet { defaults.set(calendarCountdown, forKey: "calendarCountdown") } }
    @Published var calendarLeadMinutes: Int { didSet { defaults.set(calendarLeadMinutes, forKey: "calendarLeadMinutes") } }
    /// Module colours (HUD bars, battery, timer …) or plain white.
    @Published var colorfulAccents: Bool { didSet { defaults.set(colorfulAccents, forKey: "colorfulAccents") } }
    @Published var accentMode: AccentMode { didSet { defaults.set(accentMode.rawValue, forKey: "accentMode") } }
    @Published var accentFixedColor: String { didSet { defaults.set(accentFixedColor, forKey: "accentFixedColor") } }
    @Published var islandTintColor: String { didSet { defaults.set(islandTintColor, forKey: "islandTintColor") } }
    /// Points added to the measured notch height so the closed island
    /// lines up with the camera housing (negative = shorter).
    @Published var notchHeightAdjust: Double { didSet { defaults.set(notchHeightAdjust, forKey: "notchHeightAdjust") } }
    /// Width of the open island in points.
    @Published var islandWidth: Double { didSet { defaults.set(islandWidth, forKey: "islandWidth") } }
    /// Height of the open island below the notch.
    @Published var islandHeight: Double { didSet { defaults.set(islandHeight, forKey: "islandHeight") } }
    /// Radius of the lower corners of the open island.
    @Published var islandCornerRadius: Double { didSet { defaults.set(islandCornerRadius, forKey: "islandCornerRadius") } }
    /// 0 = no shadow under the open island, 1 = strong.
    @Published var islandShadow: Double { didSet { defaults.set(islandShadow, forKey: "islandShadow") } }
    /// Thin light edge around the island.
    @Published var islandBorder: Bool { didSet { defaults.set(islandBorder, forKey: "islandBorder") } }
    @Published var fontDesign: IslandFontDesign { didSet { defaults.set(fontDesign.rawValue, forKey: "fontDesign") } }
    /// Draws all island text one step bolder.
    @Published var boldText: Bool { didSet { defaults.set(boldText, forKey: "boldText") } }
    @Published var visualizerColor: VisualizerColorMode { didSet { defaults.set(visualizerColor.rawValue, forKey: "visualizerColor") } }
    @Published var headerIconStyle: HeaderIconStyle { didSet { defaults.set(headerIconStyle.rawValue, forKey: "headerIconStyle") } }
    /// Recent calculator results, newest first.
    @Published var calculatorHistory: [String] { didSet { defaults.set(calculatorHistory, forKey: "calculatorHistory") } }

    private init() {
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        appearance = IslandAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .black
        hoverDelay = defaults.object(forKey: "hoverDelay") as? Double ?? 0.12
        animationSpeed = defaults.object(forKey: "animationSpeed") as? Double ?? 1.0
        displayID = UInt32(defaults.integer(forKey: "displayID"))
        replaceSystemHUD = defaults.object(forKey: "replaceSystemHUD") as? Bool ?? true
        showVisualizer = defaults.object(forKey: "showVisualizer") as? Bool ?? true
        moduleOrder = defaults.stringArray(forKey: "moduleOrder") ?? []
        disabledModules = Set(defaults.stringArray(forKey: "disabledModules") ?? [])
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        weatherUsesLocation = defaults.object(forKey: "weatherUsesLocation") as? Bool ?? true
        weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        weatherCoordinate = (defaults.array(forKey: "weatherCoordinate") as? [Double]).flatMap { $0.count == 2 ? $0 : nil }
        useFahrenheit = defaults.bool(forKey: "useFahrenheit")
        showLyrics = defaults.bool(forKey: "showLyrics")
        connectivityAllBluetooth = defaults.bool(forKey: "connectivityAllBluetooth")
        connectivityFocus = defaults.bool(forKey: "connectivityFocus")
        notifyDownloads = defaults.bool(forKey: "notifyDownloads")
        lockScreenWidgets = defaults.object(forKey: "lockScreenWidgets") as? Bool ?? true
        lockScreenStart = LockScreenStart(rawValue: defaults.string(forKey: "lockScreenStart") ?? "") ?? .compact
        hideInFullscreen = defaults.object(forKey: "hideInFullscreen") as? Bool ?? true
        autoUpdateCheck = defaults.object(forKey: "autoUpdateCheck") as? Bool ?? true
        screenSaverEnabled = defaults.bool(forKey: "screenSaverEnabled")
        screenSaverDelay = defaults.object(forKey: "screenSaverDelay") as? Double ?? 5
        screenSaverLyrics = defaults.object(forKey: "screenSaverLyrics") as? Bool ?? true
        sneakPeek = defaults.object(forKey: "sneakPeek") as? Bool ?? true
        sneakPeekOnSeek = defaults.object(forKey: "sneakPeekOnSeek") as? Bool ?? true
        sneakPeekDuration = defaults.object(forKey: "sneakPeekDuration") as? Double ?? 3
        sneakPeekStyle = SneakPeekStyle(rawValue: defaults.string(forKey: "sneakPeekStyle") ?? "") ?? .standard
        scrollHaptics = defaults.object(forKey: "scrollHaptics") as? Bool ?? true
        openPage = OpenPageBehavior(rawValue: defaults.string(forKey: "openPage") ?? "") ?? .first
        hiddenTabs = Set(defaults.stringArray(forKey: "hiddenTabs") ?? [])
        hudShowPercent = defaults.bool(forKey: "hudShowPercent")
        hudStyle = HUDStyle(rawValue: defaults.string(forKey: "hudStyle") ?? "") ?? .notch
        hudBarColor = HUDBarColor(rawValue: defaults.string(forKey: "hudBarColor") ?? "") ?? .colorful
        musicGesture = MusicGesture(rawValue: defaults.string(forKey: "musicGesture") ?? "") ?? .track
        keepAwakeIcon = defaults.object(forKey: "keepAwakeIcon") as? Bool ?? true
        keepAwakeLimitHours = defaults.object(forKey: "keepAwakeLimitHours") as? Int ?? 0
        batteryInHeader = defaults.object(forKey: "batteryInHeader") as? Bool ?? true
        batteryShowPercent = defaults.object(forKey: "batteryShowPercent") as? Bool ?? true
        showSource = defaults.object(forKey: "showSource") as? Bool ?? true
        lyricsColorMode = LyricsColorMode(rawValue: defaults.string(forKey: "lyricsColorMode") ?? "") ?? .cover
        lyricsFixedColor = defaults.string(forKey: "lyricsFixedColor") ?? "#FFD60A"
        hapticLevel = defaults.object(forKey: "hapticLevel") as? Int ?? TrackpadHaptics.levels
        albumTint = defaults.object(forKey: "albumTint") as? Bool ?? true
        lyricsLarge = defaults.object(forKey: "lyricsLarge") as? Bool ?? true
        shareService = ShareService(rawValue: defaults.string(forKey: "shareService") ?? "") ?? .airdrop
        calendarDaysAhead = defaults.object(forKey: "calendarDaysAhead") as? Int ?? 14
        calendarShowAllDay = defaults.object(forKey: "calendarShowAllDay") as? Bool ?? true
        calendarCountdown = defaults.object(forKey: "calendarCountdown") as? Bool ?? true
        calendarLeadMinutes = defaults.object(forKey: "calendarLeadMinutes") as? Int ?? 10
        colorfulAccents = defaults.object(forKey: "colorfulAccents") as? Bool ?? true
        accentMode = AccentMode(rawValue: defaults.string(forKey: "accentMode") ?? "") ?? .cover
        accentFixedColor = defaults.string(forKey: "accentFixedColor") ?? "#FF9F0A"
        islandTintColor = defaults.string(forKey: "islandTintColor") ?? "#1C1C3A"
        notchHeightAdjust = defaults.object(forKey: "notchHeightAdjust") as? Double ?? 0
        islandWidth = defaults.object(forKey: "islandWidth") as? Double ?? 540
        islandHeight = defaults.object(forKey: "islandHeight") as? Double ?? 150
        islandCornerRadius = defaults.object(forKey: "islandCornerRadius") as? Double ?? 34
        islandShadow = defaults.object(forKey: "islandShadow") as? Double ?? 0.45
        islandBorder = defaults.bool(forKey: "islandBorder")
        fontDesign = IslandFontDesign(rawValue: defaults.string(forKey: "fontDesign") ?? "") ?? .standard
        boldText = defaults.bool(forKey: "boldText")
        visualizerColor = VisualizerColorMode(rawValue: defaults.string(forKey: "visualizerColor") ?? "") ?? .cover
        headerIconStyle = HeaderIconStyle(rawValue: defaults.string(forKey: "headerIconStyle") ?? "") ?? .plain
        calculatorHistory = defaults.stringArray(forKey: "calculatorHistory") ?? []
    }

    var isGerman: Bool {
        switch language {
        case .de: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("de") ?? false
        }
    }

    func isEnabled(_ moduleID: String) -> Bool { !disabledModules.contains(moduleID) }

    func setEnabled(_ moduleID: String, _ enabled: Bool) {
        if enabled { disabledModules.remove(moduleID) } else { disabledModules.insert(moduleID) }
    }
}

/// Picks the German or English string according to the language setting.
/// Kept as plain code (no string catalog) so the language can switch live.
func L(_ de: String, _ en: String) -> String {
    AppSettings.shared.isGerman ? de : en
}

extension Color {
    /// "#RRGGBB" → colour; nil if the string is not a hex colour.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
