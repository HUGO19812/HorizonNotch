import AppKit
import Combine
import SwiftUI

/// Where the island's accent colour comes from.
enum AccentMode: String, CaseIterable, Identifiable {
    /// The accent colour chosen in System Settings.
    case system
    /// The colour of the current album cover (system colour without music).
    case cover
    case fixed
    var id: String { rawValue }
}

/// Colour of the audio visualizer bars.
enum VisualizerColorMode: String, CaseIterable, Identifiable {
    case cover, accent, white
    var id: String { rawValue }
}

/// How the tab icons at the top of the open island look.
enum HeaderIconStyle: String, CaseIterable, Identifiable {
    /// Icons, the active one bright.
    case plain
    /// The active icon sits in a small capsule.
    case pill
    /// Icons with a dot below the active one, in the accent colour.
    case dot
    var id: String { rawValue }
}

enum IslandFontDesign: String, CaseIterable, Identifiable {
    case standard, rounded, serif, mono
    var id: String { rawValue }

    var design: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

/// Colours resolved from the settings, handed down the island's view tree.
struct IslandTheme: Equatable {
    /// Module colours (green battery, yellow brightness …) or plain white.
    var colorful: Bool
    var accent: Color

    /// A module's own colour, or white when coloured accents are off.
    func tint(_ color: Color) -> Color { colorful ? color : .white }

    static let standard = IslandTheme(colorful: true, accent: Color(nsColor: .controlAccentColor))
}

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = IslandTheme.standard
}

extension EnvironmentValues {
    var islandTheme: IslandTheme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }
}

/// The current cover colour, kept here so the island can use it as accent
/// without knowing the media module.
final class CoverAccent: ObservableObject {
    static let shared = CoverAccent()
    /// nil while nothing with a cover plays.
    @Published var color: Color?
}

extension AppSettings {
    func theme(cover: Color?) -> IslandTheme {
        IslandTheme(colorful: colorfulAccents, accent: accentColor(cover: cover))
    }

    func accentColor(cover: Color?) -> Color {
        let system = Color(nsColor: .controlAccentColor)
        switch accentMode {
        case .system: return system
        case .cover: return cover ?? system
        case .fixed: return Color(hex: accentFixedColor) ?? system
        }
    }

    /// A module's colour (for views outside the island, e.g. the side HUD).
    func tint(_ color: Color) -> Color { colorfulAccents ? color : .white }
}
