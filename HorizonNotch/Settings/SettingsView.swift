import AppKit
import Combine
import CoreLocation
import EventKit
import SwiftUI
import UniformTypeIdentifiers

/// One page in the settings sidebar, with words the search finds it by
/// (the settings on that page, in German and English).
private struct SettingsEntry: Identifiable {
    let tab: SettingsTab
    let de: String
    let en: String
    let symbol: String
    let keywords: String
    var id: SettingsTab { tab }
    var title: String { L(de, en) }

    func matches(_ query: String) -> Bool {
        let haystack = [de, en, keywords].joined(separator: " ")
        // Every word of the query must appear somewhere.
        return query.split(separator: " ").allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

private struct SettingsGroup: Identifiable {
    let de: String
    let en: String
    let entries: [SettingsEntry]
    var id: String { en }
}

/// Like Canopy: few pages in a few groups. Pages that used to be separate
/// (behaviour, tabs, modules, lyrics, notifications, downloads) are part of
/// their natural page now.
private let settingsGroups: [SettingsGroup] = [
    SettingsGroup(de: "", en: "", entries: [
        SettingsEntry(tab: .general, de: "Allgemein", en: "General", symbol: "gearshape",
                      keywords: "Anmeldung starten Autostart login Sprache language Bildschirm display screen Monitor Verzögerung hover delay Öffnen open Reiter tab Vollbild full screen fullscreen Film movie video ausblenden hide Trackpad Klick haptic Haptik"),
        SettingsEntry(tab: .displays, de: "Bildschirme", en: "Displays", symbol: "display",
                      keywords: "Bildschirm display screen Monitor Notch Dynamic Island Design Kapsel capsule Höhe angleichen match height Vollbild full screen fullscreen ausblenden hide"),
        SettingsEntry(tab: .appearance, de: "Darstellung", en: "Appearance", symbol: "paintbrush",
                      keywords: "Notch Höhe angleichen match height Stil style Glas glass Hintergrundfarbe background colour color Rand border Akzentfarbe accent Farbig coloured Visualizer Größe size Breite width Eckenradius corner radius Schatten shadow Schrift font fett bold Reiter tabs Punkte dots Reihenfolge order Module modules einschalten ausschalten enable disable"),
    ]),
    SettingsGroup(de: "Medien", en: "Media", entries: [
        SettingsEntry(tab: .music, de: "Musik", en: "Music", symbol: "play.fill",
                      keywords: "Player Spotify Wischen swipe Geste gesture Quelle source Cover Albumfarbe album Visualizer Sneak Peek Titelwechsel Spulen seek Songtext lyrics Text Schrift Farbe gesungen sung"),
        SettingsEntry(tab: .lockScreen, de: "Sperrbildschirm", en: "Lock Screen", symbol: "lock.fill",
                      keywords: "gesperrt locked Player Musik Cover Lyrics Songtext Uhr clock Wetter Akku Kopfhörer Bildschirmschoner screen saver screensaver Durchsichtigkeit transparency"),
    ]),
    SettingsGroup(de: "Overlays", en: "Overlays", entries: [
        SettingsEntry(tab: .hud, de: "Lautstärke & Helligkeit", en: "Volume & Brightness", symbol: "speaker.wave.2.fill",
                      keywords: "HUD Ton sound volume Helligkeit brightness Tastaturlicht keyboard backlight System-Anzeige Balken bar Farbe colour weiß white Prozent percent"),
        SettingsEntry(tab: .battery, de: "Akku", en: "Battery", symbol: "bolt.fill",
                      keywords: "Batterie battery laden charging Prozent percent wach bleiben stay awake Amphetamine Koffein caffeine Kaffeetasse coffee zugeklappt lid sleep Ruhezustand"),
        SettingsEntry(tab: .connectivity, de: "Geräte & Mitteilungen", en: "Devices & Notifications", symbol: "airpodspro",
                      keywords: "Verbindungen connectivity Bluetooth AirPods Kopfhörer headphones WLAN WiFi Fokus focus Benachrichtigungen notifications Mitteilungen Downloads Fortschritt progress"),
        SettingsEntry(tab: .calendar, de: "Kalender", en: "Calendar", symbol: "calendar",
                      keywords: "Termine events ganztägig all-day Meeting Countdown Zoom Teams Meet Ansicht view"),
        SettingsEntry(tab: .weather, de: "Wetter", en: "Weather", symbol: "cloud.sun.fill",
                      keywords: "Standort location Ort place Stadt city suchen search Einheiten units Celsius Fahrenheit Temperatur"),
        SettingsEntry(tab: .shelf, de: "Ablage", en: "Shelf", symbol: "tray.full.fill",
                      keywords: "Dateien files AirDrop ziehen drag Versandart"),
        SettingsEntry(tab: .claude, de: "Claude Code", en: "Claude Code", symbol: "sparkle",
                      keywords: "Agents Agenten Hooks Token Verbrauch usage KI AI Codex"),
    ]),
    SettingsGroup(de: "System", en: "System", entries: [
        SettingsEntry(tab: .permissions, de: "Berechtigungen", en: "Permissions", symbol: "hand.raised.fill",
                      keywords: "Bedienungshilfen accessibility Kalender calendar Standort location Bluetooth Fokus focus Zugriff access Datenschutz privacy"),
    ]),
]

/// Pinned to the bottom of the sidebar, like Canopy's "License/Update".
private let footerEntry = SettingsEntry(tab: .about, de: "Info & Updates", en: "About & Updates", symbol: "arrow.down.circle",
                                        keywords: "Über About Version Info Update Aktualisierung automatisch")

private let allEntries = settingsGroups.flatMap(\.entries) + [footerEntry]

extension SettingsTab {
    /// Pages that were merged into another one show that one.
    var page: SettingsTab {
        switch self {
        case .behavior: return .general
        case .tabs, .modules: return .appearance
        case .lyrics: return .music
        case .notifications, .downloads: return .connectivity
        default: return self
        }
    }
}

struct SettingsView: View {
    let appDelegate: AppDelegate
    @ObservedObject var selection: SettingsSelection
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The groups with only the pages matching the search.
    private var visibleGroups: [SettingsGroup] {
        guard !trimmedQuery.isEmpty else { return settingsGroups }
        return settingsGroups.compactMap { group in
            let entries = group.entries.filter { $0.matches(trimmedQuery) }
            return entries.isEmpty ? nil : SettingsGroup(de: group.de, en: group.en, entries: entries)
        }
    }

    private var page: SettingsTab { selection.tab.page }

    private var footerVisible: Bool { trimmedQuery.isEmpty || footerEntry.matches(trimmedQuery) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
                .background(Color.black.opacity(0.22))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                }
            VStack(alignment: .leading, spacing: 0) {
                pageTitle
                    .padding(.horizontal, 30)
                    .padding(.top, 30)
                    .padding(.bottom, 4)
                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.18)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: trimmedQuery) { _, _ in
            // Show the first hit when the open page no longer matches.
            let hits = visibleGroups.flatMap(\.entries).map(\.tab) + (footerVisible ? [footerEntry.tab] : [])
            if let first = hits.first, !hits.contains(page) { selection.tab = first }
        }
    }

    /// Search on top, the pages in groups, "About & Updates" at the bottom.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSearchField(text: $query)
                .padding(.horizontal, 12)
                // Room for the window buttons.
                .padding(.top, 40)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleGroups) { group in
                        if !group.de.isEmpty {
                            Text(L(group.de, group.en))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.38))
                                .padding(.leading, 10)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        ForEach(group.entries) { entry in
                            SidebarRow(entry: entry, selected: page == entry.tab) { selection.tab = entry.tab }
                        }
                    }
                    if visibleGroups.isEmpty && !footerVisible {
                        Text(L("Keine Treffer", "No results"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            if footerVisible {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                SidebarRow(entry: footerEntry, selected: page == footerEntry.tab) { selection.tab = footerEntry.tab }
                    .padding(10)
            }
        }
    }

    /// "▶ Media": the page's symbol and name, large, like Canopy.
    private var pageTitle: some View {
        let entry = allEntries.first { $0.tab == page }
        return HStack(spacing: 11) {
            Image(systemName: entry?.symbol ?? "gearshape")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(entry?.title ?? "")
                .font(.system(size: 26, weight: .bold))
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .permissions:
            PermissionSettings(appDelegate: appDelegate)
        case .about:
            AboutSettings()
        default:
            SettingsPage { sections }
        }
    }

    @ViewBuilder
    private var sections: some View {
        switch page {
        case .general:
            GeneralSettings()
            BehaviorSettings()
        case .displays:
            DisplaySettings()
        case .appearance:
            AppearanceSettings()
            TabSettings(coordinator: appDelegate.coordinator)
            ModuleSettings(coordinator: appDelegate.coordinator)
        case .music:
            MusicSettings()
            LyricsSettings()
        case .lockScreen: LockScreenSettings(appDelegate: appDelegate)
        case .hud: HUDSettings()
        case .battery: BatterySettings()
        case .connectivity:
            ConnectivitySettings()
            NotificationSettings()
            DownloadSettings()
        case .calendar: CalendarSettings()
        case .weather: WeatherSettings()
        case .shelf: ShelfSettings()
        case .claude: ClaudeSettings()
        default: EmptyView()
        }
    }
}

/// The translucent, blurred window background (behind the whole window).
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Canopy look

/// The settings of a page as rounded, half-transparent cards with their
/// heading above and a short grey explanation below. Before macOS 15 the
/// sections go into a grouped form.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 15.0, *) {
            CardList { content }
        } else {
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }
}

@available(macOS 15.0, *)
private struct CardList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        if !section.header.isEmpty {
                            section.header
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.leading, 6)
                        }
                        if !section.content.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(section.content) { row in
                                    row
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                    if row.id != section.content.last?.id {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.07))
                                            .frame(height: 1)
                                            .padding(.leading, 14)
                                    }
                                }
                            }
                            .background(SettingsCardBackground())
                        }
                        if !section.footer.isEmpty {
                            section.footer
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
        .toggleStyle(CardSwitchStyle())
        .labeledContentStyle(CardLabeledStyle())
        .controlSize(.regular)
    }
}

/// A rounded, half-transparent glass card.
private struct SettingsCardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape.fill(Color.white.opacity(0.055))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// One row per switch: the text on the left, the switch on the right.
private struct CardSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardSwitchRow(configuration: configuration)
    }
}

private struct CardSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            configuration.label
                .opacity(isEnabled ? 1 : 0.45)
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Title on the left, the control on the right.
private struct CardLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
        }
    }
}

/// Canopy's search field at the top of the sidebar.
private struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            TextField(L("Suchen", "Search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// A page in the sidebar: small symbol and name, highlighted when open.
private struct SidebarRow: View {
    let entry: SettingsEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                    .frame(width: 18)
                Text(entry.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.13 : (hovering ? 0.05 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A choice as a large tile row, like Canopy's "Source: Auto / Spotify /
/// Music": a symbol or app icon on top, the name below.
private struct TileOption<Value: Hashable> {
    let value: Value
    let title: String
    var symbol: String?
    var bundleID: String?
}

private struct TilePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [TileOption<Value>]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
            HStack(spacing: 10) {
                ForEach(options.indices, id: \.self) { index in
                    tile(options[index])
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func tile(_ option: TileOption<Value>) -> some View {
        let selected = option.value == selection
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { selection = option.value } label: {
            VStack(spacing: 7) {
                icon(option)
                    .frame(width: 30, height: 30)
                Text(option.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(shape.fill(Color.white.opacity(selected ? 0.13 : 0.04)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.08),
                                        lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func icon(_ option: TileOption<Value>) -> some View {
        if let bundle = option.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: option.symbol ?? "circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// A choice as a small dark stage: optional name above, a picture below;
/// a soft light rises under the chosen item with a dot, and follows the
/// pointer while it hovers another one.
private struct StageItem<Value: Hashable> {
    let value: Value
    var title: String?
    let picture: AnyView
}

private struct StagePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [StageItem<Value>]
    var pictureSize: CGFloat = 44
    @State private var hovered: Value?
    @Namespace private var glow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                item(items[index])
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
        .background(shape.fill(Color.black))
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5))
        .clipShape(shape)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selection)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hovered)
    }

    private func item(_ item: StageItem<Value>) -> some View {
        let selected = item.value == selection
        let lit = hovered.map { $0 == item.value } ?? selected
        return Button { selection = item.value } label: {
            VStack(spacing: 12) {
                if let title = item.title {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected || lit ? 0.85 : 0.5))
                }
                item.picture
                    .frame(width: pictureSize, height: pictureSize)
                    .scaleEffect(lit ? 1.06 : 1)
                Circle()
                    .fill(Color.white.opacity(selected ? 0.9 : 0))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(alignment: .bottom) {
                if lit {
                    Ellipse()
                        .fill(RadialGradient(colors: [.white.opacity(selected ? 0.32 : 0.18), .clear],
                                             center: .center, startRadius: 0, endRadius: 60))
                        .frame(width: 120, height: 90)
                        .offset(y: 46)
                        .blur(radius: 8)
                        .matchedGeometryEffect(id: "glow", in: glow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = item.value } else if hovered == item.value { hovered = nil }
        }
    }
}

/// The player source: Auto, Spotify, Music with their app icons.
private struct SourcePicker: View {
    @Binding var selection: MediaSourceChoice

    var body: some View {
        StagePicker(selection: $selection, items: MediaSourceChoice.allCases.map { choice in
            StageItem(value: choice, title: title(choice), picture: AnyView(icon(choice)))
        })
    }

    private func title(_ choice: MediaSourceChoice) -> String {
        switch choice {
        case .auto: return "Auto"
        case .spotify: return "Spotify"
        case .music: return L("Musik", "Music")
        }
    }

    @ViewBuilder
    private func icon(_ choice: MediaSourceChoice) -> some View {
        if let bundle = choice.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "person.crop.rectangle.stack.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Clear or frosted, as two wide buttons; the chosen one lifted.
private struct GlassStylePicker: View {
    @Binding var selection: LockGlassStyle

    var body: some View {
        HStack(spacing: 12) {
            button(.clear, L("Klar", "Clear"))
            button(.frosted, L("Milchig", "Frosted"))
        }
        .animation(.easeInOut(duration: 0.2), value: selection)
    }

    private func button(_ style: LockGlassStyle, _ title: String) -> some View {
        let selected = selection == style
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { selection = style } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(shape.fill(Color.white.opacity(selected ? 0.14 : 0.04)))
                .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0.35 : 0.1), lineWidth: selected ? 1.5 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// Footer text under a settings section.
private func note(_ de: String, _ en: String) -> some View {
    Text(L(de, en)).foregroundStyle(.secondary)
}

/// Slider with its value shown on the right.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, value))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// Strength of the trackpad click when scrolling through days. Shown in
/// Behaviour, Calendar and Weather – it is one setting.
private struct HapticSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Section {
            Toggle(L("Klick auf dem Trackpad bei jedem Tag", "Trackpad click on every day"), isOn: $settings.scrollHaptics)
            LabeledContent(L("Klickstärke", "Click strength")) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(settings.hapticLevel) },
                                          set: { settings.hapticLevel = Int($0.rounded()) }),
                           in: 1...Double(TrackpadHaptics.levels), step: 1, onEditingChanged: { editing in
                        if !editing { TrackpadHaptics.click(level: settings.hapticLevel) }
                    })
                    Image(systemName: "hand.tap.fill").foregroundStyle(.secondary)
                    Text("\(settings.hapticLevel)/\(TrackpadHaptics.levels)")
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                    Button(L("Testen", "Test")) { TrackpadHaptics.click(level: settings.hapticLevel) }
                }
            }
            .disabled(!settings.scrollHaptics)
        } header: {
            Text(L("Blättern durch Tage", "Scrolling through days"))
        } footer: {
            note("Gilt für Kalender und Wetter. Den Klick spürst du nur mit der Hand auf dem Trackpad – „Testen“ spielt ihn ab.",
                 "Applies to calendar and weather. You only feel the click with your hand on the trackpad – “Test” plays it.")
        }
    }
}

// MARK: - App

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Toggle(L("Bei der Anmeldung starten", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.set(value) }
                Picker(L("Sprache", "Language"), selection: $settings.language) {
                    Text(L("Systemsprache", "System language")).tag(AppLanguage.system)
                    Text("Deutsch").tag(AppLanguage.de)
                    Text("English").tag(AppLanguage.en)
                }
            }
        }
    }
}

/// Which screen, notch or Dynamic Island, and how the island fits it.
private struct DisplaySettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                HStack(spacing: 18) {
                    DesignOption(design: .notch, selection: $settings.islandDesign)
                    DesignOption(design: .dynamicIsland, selection: $settings.islandDesign)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Design")
            } footer: {
                note("Die Notch hängt an der Oberkante und wächst aus dem Kameragehäuse. Die Dynamic Island schwebt knapp darunter als Kapsel wie beim iPhone und ist nur dort mit der Kante verbunden, wo die Kamera sitzt.",
                     "The notch hangs from the top edge, growing out of the camera housing. The Dynamic Island floats just below the edge, a capsule as on iPhone, joined to the edge only where the camera sits.")
            }
            Section {
                TilePicker(title: L("Notch zeigen auf", "Show the notch on"), selection: $settings.displayMode, options: [
                    TileOption(value: DisplayMode.chosen, title: L("Einem Bildschirm", "One display"), symbol: "display"),
                    TileOption(value: DisplayMode.all, title: L("Jedem Bildschirm", "Every display"), symbol: "display.2"),
                    TileOption(value: DisplayMode.followMouse, title: L("Wo die Maus ist", "Where the mouse is"),
                               symbol: "cursorarrow.motionlines"),
                ])
            } footer: {
                note("„Wo die Maus ist“ lässt die geschlossene Notch auf den Bildschirm wandern, auf dem gerade der Zeiger ist. Bei „Jedem Bildschirm“ hat jeder Bildschirm seine eigene Notch.",
                     "“Where the mouse is” moves the closed notch to the display the pointer is on. With “Every display” each display gets its own notch.")
            }
            Section {
                Picker(L("Bildschirm", "Display"), selection: $settings.displayID) {
                    Text(L("Automatisch", "Automatic")).tag(UInt32(0))
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName + (screen.hasNotch ? " (Notch)" : "")).tag(screen.displayID)
                    }
                .disabled(settings.displayMode == .followMouse)
                }
            } footer: {
                note("Automatisch nimmt den Bildschirm mit Notch, sonst den Hauptbildschirm. Ohne Notch erscheint eine schwebende Kapsel.",
                     "Automatic picks the display with a notch, otherwise the main display. Without a notch a floating capsule appears.")
            }
            Section {
                ValueSlider(title: L("Höhe an Notch angleichen", "Match notch height"), value: $settings.notchHeightAdjust,
                            range: -8...4, step: 0.5, format: "%+.1f pt")
            } footer: {
                note("Feinabstimmung, falls die geschlossene Island nicht genau so hoch ist wie die Kamera-Aussparung.",
                     "Fine-tuning in case the closed island is not exactly as tall as the camera housing.")
            }
            Section {
                Toggle(L("Im Vollbild ausblenden", "Hide in full screen"), isOn: $settings.hideInFullscreen)
            } footer: {
                note("Schaust du einen Film oder nutzt eine App im Vollbild, verschwindet die Island. Lautstärke- und Helligkeitsanzeigen erscheinen trotzdem kurz.",
                     "While you watch a film or use an app in full screen, the island disappears. Volume and brightness overlays still show briefly.")
            }
        }
    }
}

/// A small picture of the design with a radio mark below.
private struct DesignOption: View {
    let design: IslandDesign
    @Binding var selection: IslandDesign

    var body: some View {
        let selected = design == selection
        Button { selection = design } label: {
            VStack(spacing: 10) {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.5), Color(red: 0.55, green: 0.35, blue: 0.95),
                                            Color(red: 0.4, green: 0.65, blue: 0.95)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 14)
                    if design == .notch { notchPicture } else { islandPicture }
                }
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: selected ? 3 : 1))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(design == .notch ? "Notch" : "Dynamic Island")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: selected)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [.pink, .purple, .blue], startPoint: .top, endPoint: .bottom))
    }

    private var notchPicture: some View {
        HStack(spacing: 12) {
            tile.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.white.opacity(0.85)).frame(width: 80, height: 5)
                Capsule().fill(Color.white.opacity(0.4)).frame(width: 52, height: 4)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.7)).frame(width: 5, height: 5) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 78)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
            .fill(Color.black))
        .padding(.horizontal, 10)
    }

    private var islandPicture: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.black).frame(width: 60, height: 8)
            HStack {
                tile.frame(width: 12, height: 12)
                Spacer()
                HStack(spacing: 2) {
                    ForEach([5.0, 9, 6, 8], id: \.self) { height in
                        Capsule().fill(Color.pink).frame(width: 2, height: height)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 150, height: 22)
            .background(Capsule().fill(Color.black))
            .padding(.top, 4)
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                TilePicker(title: L("Stil der Island", "Island style"), selection: $settings.appearance, options: [
                    TileOption(value: IslandAppearance.black, title: L("Schwarz", "Black"), symbol: "circle.fill"),
                    TileOption(value: IslandAppearance.tinted, title: L("Farbig", "Tinted"), symbol: "paintpalette.fill"),
                ])
                if settings.appearance == .tinted {
                    ColorPicker(L("Hintergrundfarbe", "Background colour"), selection: hexBinding(\.islandTintColor),
                                supportsOpacity: false)
                }
                Toggle(L("Feiner heller Rand", "Thin light edge"), isOn: $settings.islandBorder)
                ValueSlider(title: L("Schatten", "Shadow"), value: $settings.islandShadow,
                            range: 0...1, step: 0.05, format: "%.2f")
            } header: {
                Text(L("Hintergrund", "Background"))
            } footer: {
                note("Geschlossen ist die Island immer schwarz, damit sie mit der Notch verschmilzt.",
                     "Closed, the island is always black so it blends with the notch.")
            }
            Section {
                Picker(L("Akzentfarbe", "Accent colour"), selection: $settings.accentMode) {
                    Text(L("Systemfarbe", "System colour")).tag(AccentMode.system)
                    Text(L("Farbe des Covers", "Cover colour")).tag(AccentMode.cover)
                    Text(L("Feste Farbe", "Fixed colour")).tag(AccentMode.fixed)
                }
                if settings.accentMode == .fixed {
                    ColorPicker(L("Eigene Akzentfarbe", "Custom accent"), selection: hexBinding(\.accentFixedColor),
                                supportsOpacity: false)
                }
                Toggle(L("Farbige Modul-Anzeigen", "Coloured module indicators"), isOn: $settings.colorfulAccents)
                Picker(L("Farbe des Visualizers", "Visualizer colour"), selection: $settings.visualizerColor) {
                    Text(L("Farbe des Covers", "Cover colour")).tag(VisualizerColorMode.cover)
                    Text(L("Akzentfarbe", "Accent colour")).tag(VisualizerColorMode.accent)
                    Text(L("Weiß", "White")).tag(VisualizerColorMode.white)
                }
            } header: {
                Text(L("Farben", "Colours"))
            } footer: {
                note("Akzentfarbe: aktiver Reiter und Ablage. „Farbige Modul-Anzeigen“ aus macht Helligkeits- und Tastaturlicht-Balken, Akku, Timer, Downloads, Kamera/Mikrofon, Kalender-Countdown, Meldungen und Claude-Status weiß.",
                     "Accent: active tab and shelf. Turning “Coloured module indicators” off makes brightness and keyboard bars, battery, timer, downloads, camera/mic, calendar countdown, events and Claude status white.")
            }
            Section(L("Größe & Form", "Size & shape")) {
                ValueSlider(title: L("Breite geöffnet", "Open width"), value: $settings.islandWidth,
                            range: 480...660, step: 10, format: "%.0f pt")
                ValueSlider(title: L("Höhe geöffnet", "Open height"), value: $settings.islandHeight,
                            range: 140...200, step: 5, format: "%.0f pt")
                ValueSlider(title: L("Eckenradius", "Corner radius"), value: $settings.islandCornerRadius,
                            range: 16...48, step: 1, format: "%.0f pt")
            }
            Section(L("Schrift & Symbole", "Text & icons")) {
                Picker(L("Schriftart", "Font"), selection: $settings.fontDesign) {
                    Text(L("Standard", "Standard")).tag(IslandFontDesign.standard)
                    Text(L("Abgerundet", "Rounded")).tag(IslandFontDesign.rounded)
                    Text(L("Serifen", "Serif")).tag(IslandFontDesign.serif)
                    Text(L("Monospace", "Monospace")).tag(IslandFontDesign.mono)
                }
                Toggle(L("Kräftigere Schrift", "Bolder text"), isOn: $settings.boldText)
                Picker(L("Reiter-Symbole", "Tab icons"), selection: $settings.headerIconStyle) {
                    Text(L("Schlicht", "Plain")).tag(HeaderIconStyle.plain)
                    Text(L("Kapsel", "Capsule")).tag(HeaderIconStyle.pill)
                    Text(L("Punkt", "Dot")).tag(HeaderIconStyle.dot)
                    Text(L("Seitenpunkte", "Page dots")).tag(HeaderIconStyle.pageDots)
                }
                .pickerStyle(.segmented)
                Toggle(L("Namen des aktiven Reiters zeigen", "Show the active tab's name"), isOn: $settings.headerActiveLabel)
                Toggle(L("Live-Infos bei den Reitern (Timer, Temperatur, Datum, Ablage)",
                         "Live info on the tabs (timer, temperature, date, shelf)"), isOn: $settings.headerLiveInfo)
                Toggle(L("Koffein und Akku in einer Glas-Kapsel", "Keep-awake and battery in a glass capsule"),
                       isOn: $settings.headerStatusGroup)
            }
            Section {
                ValueSlider(title: L("Animationstempo", "Animation speed"), value: $settings.animationSpeed,
                            range: 0.5...1.8, step: 0.1, format: "%.1f×")
            }
        }
    }
}

private func hexBinding(_ key: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<Color> {
    Binding(get: { Color(hex: AppSettings.shared[keyPath: key]) ?? .white },
            set: { AppSettings.shared[keyPath: key] = $0.hexString })
}

private struct BehaviorSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                ValueSlider(title: L("Verzögerung beim Überfahren", "Hover delay"), value: $settings.hoverDelay,
                            range: 0...0.8, step: 0.05, format: "%.2f s")
            } footer: {
                note("So lange muss der Zeiger auf der Notch liegen, bis die Island aufgeht. Ein Klick öffnet sie sofort.",
                     "How long the pointer has to rest on the notch before the island opens. A click opens it at once.")
            }
            Section {
                Picker(L("Beim Öffnen zeigen", "When opening, show"), selection: $settings.openPage) {
                    Text(L("Ersten Reiter", "First tab")).tag(OpenPageBehavior.first)
                    Text(L("Zuletzt geöffneten Reiter", "Last opened tab")).tag(OpenPageBehavior.last)
                }
            } footer: {
                note("Der erste Reiter ist standardmäßig Musik. Die Reihenfolge stellst du unter „Reiter“ ein.",
                     "The first tab is Music by default. Change the order under “Tabs”.")
            }
            HapticSection()
        }
    }
}

// MARK: - Island

private struct ModuleRow: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

/// Order and visibility of the pages in the open island: one tile per
/// page (symbol, name, switch) in a row; drag a tile to move it.
private struct TabSettings: View {
    let coordinator: NotchCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var dragging: String?

    private var rows: [ModuleRow] {
        let order = settings.moduleOrder
        let registered = coordinator.modules.map(\.id)
        return coordinator.modules.filter(\.hasExpandedContent)
            .map { ModuleRow(id: $0.id, title: $0.title, symbol: $0.symbol) }
            .sorted { a, b in
                let ra = (order.firstIndex(of: a.id) ?? Int.max, registered.firstIndex(of: a.id) ?? Int.max)
                let rb = (order.firstIndex(of: b.id) ?? Int.max, registered.firstIndex(of: b.id) ?? Int.max)
                return ra < rb
            }
    }

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(rows) { row in
                            tile(row)
                                .onDrag {
                                    dragging = row.id
                                    return NSItemProvider(object: row.id as NSString)
                                }
                                .onDrop(of: [.text], delegate: TileDrop(target: row.id, rows: rows.map(\.id),
                                                                       dragging: $dragging, settings: settings))
                        }
                    }
                    .padding(10)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: rows.map(\.id))
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.18)))
            } header: {
                HStack {
                    Text(L("In der geöffneten Notch", "In the open notch"))
                    Spacer()
                    Button(L("Standard-Reihenfolge", "Default order")) { settings.moduleOrder = [] }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            } footer: {
                note("Zieh eine Kachel an die gewünschte Stelle; ihr Schalter entscheidet, ob die Notch die Seite überhaupt hat. In der geöffneten Notch liegen sie von links nach rechts in dieser Reihenfolge – mit zwei Fingern seitlich wischen oder die Punkte anklicken. Ausgeschaltete Seiten werden übersprungen und laufen im Hintergrund weiter (ein Timer zeigt z. B. trotzdem seinen Countdown).",
                     "Drag a tile to where you want it; its switch decides whether the notch has the page at all. In the open notch they lie left to right in this order – swipe sideways with two fingers, or click the dots. A page switched off is skipped and keeps working in the background (a timer still shows its countdown, for example).")
            }
        }
    }

    private func tile(_ row: ModuleRow) -> some View {
        let visible = !settings.hiddenTabs.contains(row.id)
        let always = row.id == "media"
        return VStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(always ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                                 : AnyShapeStyle(Color.accentColor.opacity(0.35))))
            Text(row.title)
                .font(.system(size: 11.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 30)
            if always {
                Text(L("Immer an", "Always on"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
            } else {
                Toggle("", isOn: Binding(
                    get: { visible },
                    set: { on in
                        if on { settings.hiddenTabs.remove(row.id) } else { settings.hiddenTabs.insert(row.id) }
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(height: 22)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 92)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// Moves the dragged tile to where it hovers, live.
private struct TileDrop: DropDelegate {
    let target: String
    let rows: [String]
    @Binding var dragging: String?
    let settings: AppSettings

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = rows.firstIndex(of: dragging), let to = rows.firstIndex(of: target) else { return }
        var ids = rows
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        settings.moduleOrder = ids
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Switches whole modules on or off (tab and live activity).
private struct ModuleSettings: View {
    let coordinator: NotchCoordinator
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                ForEach(coordinator.modules.map { ModuleRow(id: $0.id, title: $0.title, symbol: $0.symbol) }) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.symbol)
                            .frame(width: 22)
                            .foregroundStyle(.secondary)
                        Toggle(row.title, isOn: Binding(
                            get: { settings.isEnabled(row.id) },
                            set: { settings.setEnabled(row.id, $0) }))
                    }
                }
            } footer: {
                note("Ein abgeschaltetes Modul verschwindet ganz: kein Reiter und keine Anzeige neben der Notch.",
                     "A disabled module disappears completely: no tab and nothing next to the notch.")
            }
        }
    }
}

// MARK: - Features

private struct MusicSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Quelle", "Source"))
                    SourcePicker(selection: $settings.mediaSource)
                }
            } footer: {
                note("Auto zeigt, was gerade spielt (auch Browser). Spotify oder Musik zeigt nur diese App.",
                     "Auto shows whatever plays (browsers too). Spotify or Music shows only that app.")
            }
            Section {
                TilePicker(title: L("Mit zwei Fingern seitlich wischen", "Two-finger sideways swipe"), selection: $settings.musicGesture, options: [
                    TileOption(value: MusicGesture.tabs, title: L("Reiter wechseln", "Switch tabs"), symbol: "rectangle.on.rectangle"),
                    TileOption(value: MusicGesture.track, title: L("Titel wechseln", "Change track"), symbol: "forward.end.fill"),
                    TileOption(value: MusicGesture.seek, title: L("10 s spulen", "Seek 10 s"), symbol: "goforward.10"),
                    TileOption(value: MusicGesture.off, title: L("Aus", "Off"), symbol: "hand.raised.slash"),
                ])
            } header: {
                Text(L("Gesten", "Gestures"))
            } footer: {
                note("Nach links = nächster Reiter bzw. Titel, nach rechts = zurück; mit Trackpad-Klick. Liegt der Zeiger auf einer Tages- oder Stundenleiste (Kalender, Wetter), scrollt das Wischen diese. „Titel wechseln“ und „10 s spulen“ gelten nur im Musik-Reiter.",
                     "Left = next tab or track, right = back; with a trackpad click. With the pointer on a day or hour strip (calendar, weather) the swipe scrolls it. “Change track” and “Seek 10 s” only apply on the music tab.")
            }
            Section(L("Player", "Player")) {
                Toggle(L("Quelle unter dem Cover anzeigen", "Show the source below the cover"), isOn: $settings.showSource)
                Toggle(L("Albumfarbe für Schein, Balken und Hervorhebungen", "Album colour for glow, bars and highlights"),
                       isOn: $settings.albumTint)
                Toggle(L("Audio-Visualizer", "Audio visualizer"), isOn: $settings.showVisualizer)
                if settings.showVisualizer {
                    Picker(L("Rechts in der Notch", "Right of the notch"), selection: $settings.compactIndicator) {
                        Text(L("Wellen", "Waves")).tag(CompactMusicIndicator.waves)
                        Text(L("Fortschrittsring", "Progress ring")).tag(CompactMusicIndicator.ring)
                        Text(L("Pulsierender Punkt", "Breathing dot")).tag(CompactMusicIndicator.dot)
                    }
                }
            }
            Section {
                Toggle(L("Bei Start und Titelwechsel", "On play and track change"), isOn: $settings.sneakPeek)
                Toggle(L("Beim Vor- und Zurückspulen", "When seeking"), isOn: $settings.sneakPeekOnSeek)
                    .disabled(!settings.sneakPeek)
                Picker(L("Stil", "Style"), selection: $settings.sneakPeekStyle) {
                    Text(L("Unter der Notch", "Below the notch")).tag(SneakPeekStyle.standard)
                    Text(L("Neben der Notch", "Beside the notch")).tag(SneakPeekStyle.inline)
                }
                .disabled(!settings.sneakPeek)
                ValueSlider(title: L("Dauer", "Duration"), value: $settings.sneakPeekDuration,
                            range: 1.5...6, step: 0.5, format: "%.1f s")
                    .disabled(!settings.sneakPeek)
            } header: {
                Text("Sneak Peek")
            } footer: {
                note("Zeigt kurz den Titel, ohne die Island zu öffnen.", "Briefly shows the song without opening the island.")
            }
        }
    }
}

private struct LyricsSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Toggle(L("Songtext-Feld neben dem Player", "Lyrics field next to the player"), isOn: $settings.showLyrics)
                Toggle(L("Große Schrift", "Large text"), isOn: $settings.lyricsLarge)
                    .disabled(!settings.showLyrics)
                ValueSlider(title: L("Zeitversatz", "Timing offset"), value: $settings.lyricsOffset,
                            range: -3...3, step: 0.1, format: "%+.1f s")
            } footer: {
                note("Synchronisierte Songtexte von LRCLIB. Ein Klick auf eine Zeile springt dorthin.",
                     "Synced lyrics from LRCLIB. Click a line to jump there.")
            }
            Section(L("Farbe der gesungenen Wörter", "Colour of sung words")) {
                Picker(L("Farbe", "Colour"), selection: $settings.lyricsColorMode) {
                    Text(L("Weiß auf Grau (wie Musik)", "White on grey (like Music)")).tag(LyricsColorMode.music)
                    Text(L("Albumfarbe", "Album colour")).tag(LyricsColorMode.cover)
                    Text(L("Feste Farbe", "Fixed colour")).tag(LyricsColorMode.fixed)
                }
                .pickerStyle(.radioGroup)
                if settings.lyricsColorMode == .fixed {
                    ColorPicker(L("Eigene Farbe", "Custom colour"), selection: Binding(
                        get: { Color(hex: settings.lyricsFixedColor) ?? .yellow },
                        set: { settings.lyricsFixedColor = $0.hexString }), supportsOpacity: false)
                }
            }
        }
    }
}

private struct HUDSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Toggle(L("System-Anzeige ersetzen", "Replace the system overlay"), isOn: $settings.replaceSystemHUD)
            } footer: {
                note("Gilt für Lautstärke, Stummschaltung, Bildschirmhelligkeit und Tastaturlicht. Braucht die Bedienungshilfen-Berechtigung.",
                     "Covers volume, mute, display brightness and keyboard light. Needs the Accessibility permission.")
            }
            Section(L("Darstellung", "Look")) {
                Toggle(L("Prozentzahl anzeigen", "Show percentage"), isOn: $settings.hudShowPercent)
                Picker(L("Balkenfarbe", "Bar colour"), selection: $settings.hudBarColor) {
                    Text(L("Weiß", "White")).tag(HUDBarColor.white)
                    Text(L("Farbig", "Coloured")).tag(HUDBarColor.colorful)
                }
                .pickerStyle(.segmented)
                note("Farbig: Lautstärke in der Akzentfarbe, Helligkeit gelb, Tastaturlicht blau.",
                     "Coloured: volume in the accent colour, brightness yellow, keyboard light blue.")
            }
        }
    }
}

private struct CalendarSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section(L("Ansicht", "View")) {
                Stepper(value: $settings.calendarDaysAhead, in: 3...60) {
                    Text(L("Tage voraus in der Datumsleiste: \(settings.calendarDaysAhead)",
                           "Days ahead in the date strip: \(settings.calendarDaysAhead)"))
                }
                Toggle(L("Ganztägige Termine anzeigen", "Show all-day events"), isOn: $settings.calendarShowAllDay)
                Toggle(L("To-dos aus Erinnerungen daneben", "To-dos from Reminders beside them"), isOn: $settings.calendarShowReminders)
            }
            HapticSection()
            Section(L("Meeting-Countdown", "Meeting countdown")) {
                Toggle(L("Countdown neben der Notch", "Countdown next to the notch"), isOn: $settings.calendarCountdown)
                Stepper(value: $settings.calendarLeadMinutes, in: 1...60) {
                    Text(L("\(settings.calendarLeadMinutes) Min. vor Beginn", "\(settings.calendarLeadMinutes) min before start"))
                }
                .disabled(!settings.calendarCountdown)
            }
        }
    }
}

/// Search field for a place; the hits are listed below it and a click
/// picks one. Shown when the current location is switched off.
private struct PlaceSearch: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var results: [WeatherService.Place] = []
    @State private var searching = false
    /// The query the current results belong to.
    @State private var searched = ""

    var body: some View {
        if !settings.weatherCity.isEmpty {
            LabeledContent(L("Ort", "Place")) {
                Label(settings.weatherCity, systemImage: "mappin.and.ellipse")
            }
        }
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Ort suchen", "Search place"), text: $query, prompt: Text(L("z. B. Innsbruck", "e.g. Innsbruck")))
                .textFieldStyle(.plain)
            if searching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .task(id: query) {
            // Debounce: a new keystroke cancels this task during the sleep.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                results = []
                searched = ""
                searching = false
                return
            }
            searching = true
            let found = await WeatherService.searchPlaces(text, german: settings.isGerman)
            guard !Task.isCancelled else { return }
            results = found
            searched = text
            searching = false
        }
        if !searched.isEmpty && !searching && results.isEmpty {
            Text(L("Kein Ort gefunden", "No place found")).foregroundStyle(.secondary)
        }
        ForEach(results) { place in
            Button { pick(place) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name)
                        if !place.region.isEmpty {
                            Text(place.region).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isPicked(place) {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func isPicked(_ place: WeatherService.Place) -> Bool {
        settings.weatherCoordinate == [place.latitude, place.longitude]
    }

    private func pick(_ place: WeatherService.Place) {
        settings.weatherCoordinate = [place.latitude, place.longitude]
        settings.weatherCity = place.name
        query = ""
        results = []
        searched = ""
    }
}

private struct WeatherSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Toggle(L("Aktuellen Standort verwenden", "Use current location"), isOn: $settings.weatherUsesLocation)
                if !settings.weatherUsesLocation {
                    PlaceSearch()
                }
            } footer: {
                note("Wetterdaten von Open-Meteo, ohne Konto.", "Weather data from Open-Meteo, no account needed.")
            }
            Section {
                Toggle(L("Hinweis, wenn es bald regnet", "Notice when rain is coming"), isOn: $settings.weatherRainAlert)
            } footer: {
                note("Kurz in der Notch, wenn es in den nächsten zwei Stunden an deinem Ort zu regnen beginnt – einmal pro Schauer. Lädt dafür alle 15 Minuten die Vorhersage.",
                     "Briefly in the notch when rain starts at your place within the next two hours – once per shower. Loads the forecast every 15 minutes for it.")
            }
            Section {
                Picker(L("Einheiten", "Units"), selection: $settings.useFahrenheit) {
                    Text("°C · km/h").tag(false)
                    Text("°F · mph").tag(true)
                }
                .pickerStyle(.segmented)
            }
            HapticSection()
        }
    }
}

private struct ShelfSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Picker(L("Versandart", "Send via"), selection: $settings.shareService) {
                    ForEach(ShareService.allCases) { service in
                        Label(service.title, systemImage: service.symbol).tag(service)
                    }
                }
            } footer: {
                note("Das kleine Feld links in der Ablage sendet Dateien auf diesem Weg.",
                     "The small field on the left of the shelf sends files this way.")
            }
        }
    }
}

private struct ConnectivitySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var customPicture = NSImage(contentsOf: DevicePhotos.customURL)
    @State private var hasModel = CustomDeviceModel.pro.url != nil

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Darstellung der Kopfhörer", "Headphone style"))
                    StagePicker(selection: $settings.accessoryStyle, items: [
                        StageItem(value: AccessoryStyle.model3D, picture: AnyView(
                            Group {
                                if hasModel {
                                    DeviceModelView(model: .pro, spinning: false)
                                } else if let custom = customPicture {
                                    Image(nsImage: custom).resizable().scaledToFit()
                                } else {
                                    AirPodsPairView(spinning: false)
                                }
                            })),
                        StageItem(value: AccessoryStyle.glyph, picture: AnyView(
                            Image(systemName: "airpods")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.white))),
                    ], pictureSize: 64)
                }
                HStack {
                    Text(L("Ausprobieren", "Try it"))
                    Spacer()
                    ForEach(CustomDeviceModel.allCases) { kind in
                        Button(kind.sampleName) { NotificationCenter.default.post(name: .testDeviceCard, object: kind.sampleName) }
                    }
                }
            } footer: {
                note("Links deine Kopfhörer als 3D-Modell oder Bild, rechts das schlichte Systemsymbol. „Ausprobieren“ zeigt die Karte beim Verbinden und Trennen.",
                     "Left your headphones as a 3D model or picture, right the plain system glyph. “Try it” shows the card on connecting and disconnecting.")
            }
            Section {
                Toggle(L("Alle Bluetooth-Geräte und AirPods-Akku", "All Bluetooth devices and AirPods battery"),
                       isOn: $settings.connectivityAllBluetooth)
                Toggle(L("Fokus ein/aus", "Focus on/off"), isOn: $settings.connectivityFocus)
            } footer: {
                note("Kopfhörer und WLAN-Wechsel erscheinen immer, ohne Berechtigung. Die beiden Optionen fragen beim Einschalten nach Bluetooth bzw. dem Fokus-Status.",
                     "Headphones and Wi-Fi changes always show, without a permission. The two options ask for Bluetooth or Focus status when switched on.")
            }
        }
    }
}

private struct NotificationSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Toggle(L("Fertige Downloads", "Finished downloads"), isOn: $settings.notifyDownloads)
            } footer: {
                note("Fragt beim Einschalten nach Zugriff auf den Downloads-Ordner. Mitteilungen anderer Apps gibt macOS nicht an Dritt-Apps weiter.",
                     "Asks for access to the Downloads folder when switched on. macOS does not pass other apps' notifications to third-party apps.")
            }
        }
    }
}

private struct BatterySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section(L("Anzeige", "Display")) {
                Toggle(L("Akku oben rechts in der geöffneten Island", "Battery at the top right of the open island"),
                       isOn: $settings.batteryInHeader)
                Toggle(L("Prozent anzeigen", "Show percentage"), isOn: $settings.batteryShowPercent)
                    .disabled(!settings.batteryInHeader)
            }
            Section {
                Toggle(L("Wach bleiben, auch zugeklappt", "Stay awake, also with the lid closed"), isOn: Binding(
                    get: { awake.isOn }, set: { awake.set($0) }))
                Toggle(L("Bildschirm beim Zuklappen ausschalten", "Turn the screen off when the lid closes"),
                       isOn: $settings.keepAwakeScreenOffWhenClosed)
                Picker(L("Höchstens", "At most"), selection: $settings.keepAwakeLimitHours) {
                    Text(L("Unbegrenzt", "No limit")).tag(0)
                    ForEach([1, 2, 3, 4, 6, 8, 12], id: \.self) { hours in
                        Text(L("\(hours) Std.", "\(hours) h")).tag(hours)
                    }
                }
                if awake.isOn, let end = awake.endDate {
                    LabeledContent(L("Schaltet sich aus um", "Switches off at")) {
                        Text(end, style: .time)
                    }
                }
                Toggle(L("Knopf (Kaffeetasse) oben in der Island", "Button (coffee cup) at the top of the island"), isOn: $settings.keepAwakeIcon)
                if awake.isSetUp {
                    HStack {
                        Label(L("Schalten ohne Passwort ist eingerichtet", "Switching without a password is set up"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(L("Entfernen", "Remove")) { awake.removeSetup() }
                    }
                }
                if let error = awake.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text(L("Wach bleiben", "Stay awake"))
            } footer: {
                note("Bleibt an, bis du es ausschaltest oder die eingestellte Höchstdauer um ist – auch nach einem Neustart. Die Höchstdauer gilt ab dem Einschalten; eine Änderung wirkt beim nächsten Einschalten. Dafür nutzt macOS „pmset disablesleep“. Nur beim allerersten Mal fragt macOS nach deinem Passwort; danach darf Horizon Notch genau diesen einen Befehl ohne Passwort ausführen (wie Amphetamine Enhancer). Achtung: Zugeklappt in der Tasche kann der Mac warm werden.",
                     "Stays on until you switch it off or the time limit is up – also after a restart. The limit counts from switching on; a change applies the next time you switch it on. macOS uses “pmset disablesleep” for this. Only the very first time macOS asks for your password; after that Horizon Notch may run exactly this one command without a password (like Amphetamine Enhancer). Careful: closed in a bag the Mac can get warm.")
            }
        }
    }
}

private struct DownloadSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                Toggle(L("Laufende und fertige Downloads anzeigen", "Show running and finished downloads"), isOn: $settings.notifyDownloads)
                Toggle(L("Fortschritt beim Kopieren großer Dateien", "Progress when copying large files"), isOn: $settings.notifyCopies)
            } footer: {
                note("Zeigt Fortschritt neben der Notch, solange Safari, Chrome & Co. in den Downloads-Ordner laden, und meldet fertige Dateien. Fragt beim Einschalten nach Zugriff auf den Downloads-Ordner.",
                     "Shows progress next to the notch while Safari, Chrome & co. download into the Downloads folder, and reports finished files. Asks for access to the Downloads folder when switched on.")
            }
        }
    }
}

private struct ClaudeSettings: View {
    @State private var installed = ClaudeHooks.isInstalled
    @State private var error: String?

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                HStack {
                    Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(installed ? .green : .secondary)
                    Text(installed ? L("Hooks sind eingerichtet", "Hooks are set up") : L("Hooks nicht eingerichtet", "Hooks not set up"))
                    Spacer()
                    Button(installed ? L("Entfernen", "Remove") : L("Einrichten", "Set up")) {
                        do {
                            if installed { try ClaudeHooks.uninstall() } else { try ClaudeHooks.install() }
                            error = nil
                        } catch let failure {
                            error = failure.localizedDescription
                        }
                        installed = ClaudeHooks.isInstalled
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                LabeledContent(L("Letztes Ereignis von Claude Code", "Last event from Claude Code")) {
                    HStack(spacing: 10) {
                        if let last = UserDefaults.standard.object(forKey: "claudeLastEvent") as? Date {
                            Text(last, style: .relative).foregroundStyle(.secondary)
                        } else {
                            Text(L("noch keines", "none yet")).foregroundStyle(.orange)
                        }
                        Button(L("Notch testen", "Test the notch")) { ClaudeHooks.sendTest() }
                    }
                }
            } header: {
                Text(L("Status in der Notch", "Status in the notch"))
            } footer: {
                note("Trägt in ~/.claude/settings.json Hooks ein, die bei jedem Claude-Code-Ereignis ein kleines Skript starten (vorher wird eine Sicherung angelegt). Neue Sitzungen zeigen dann neben der Notch, ob Claude arbeitet, auf dich wartet oder fertig ist. Bereits laufende Sitzungen erst nach einem Neustart.",
                     "Adds hooks to ~/.claude/settings.json that run a small script on every Claude Code event (a backup is made first). New sessions then show next to the notch whether Claude is working, waiting for you or done. Sessions already running only after a restart.")
            }
            Section {
                Text(L("Der Reiter „Claude Code“ zeigt den Token-Verbrauch von heute und im aktuellen 5-Stunden-Fenster, gelesen aus den lokalen Protokollen in ~/.claude/projects. Der Dollar-Betrag ist ein Schätzwert nach API-Preisen (von OpenRouter) – mit einem Abo zahlst du ihn nicht.",
                       "The “Claude Code” tab shows today's token usage and the current 5-hour window, read from the local logs in ~/.claude/projects. The dollar amount estimates API prices (from OpenRouter) – on a subscription you don't pay it."))
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("KI-Verbrauch", "AI usage"))
            }
        }
    }
}

private struct LockScreenSettings: View {
    let appDelegate: AppDelegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                LockScreenPreview()
            }
            Section {
                GlassStylePicker(selection: $settings.lockGlassStyle)
                Toggle(L("Apples Liquid Glass verwenden", "Use Apple's Liquid Glass"), isOn: $settings.lockSystemGlass)
            } header: {
                Text(L("Glas", "Glass style"))
            } footer: {
                note("Klar lässt den Hintergrund durchscheinen, nur der Rand bricht ihn. Milchig zeichnet ihn weich. Das Glas nimmt das Bild, das macOS selbst für den Sperrbildschirm bereithält – ohne Bildschirmaufnahme. „Apples Liquid Glass“ nutzt das Glas des Systems statt des eigenen.",
                     "Clear lets the background show through, only the rim bends it. Frosted blurs it softly. The glass uses the picture macOS itself keeps for the lock screen – no screen recording. “Apple's Liquid Glass” uses the system's glass instead of our own.")
            }
            Section {
                Toggle(L("Musik-Player auf dem Sperrbildschirm", "Music player on the lock screen"), isOn: $settings.lockScreenWidgets)
                Toggle(L("Wetter, Akku und Kopfhörer unter der Uhr", "Weather, battery and headphones under the clock"),
                       isOn: $settings.lockScreenStatusRow)
                    .disabled(!settings.lockScreenWidgets)
                TilePicker(title: L("Beim Sperren zeigen", "When locking, show"), selection: $settings.lockScreenStart, options: [
                    TileOption(value: LockScreenStart.compact, title: L("Kleiner Player", "Small player"), symbol: "play.rectangle"),
                    TileOption(value: LockScreenStart.cover, title: L("Großes Cover", "Large cover"), symbol: "photo"),
                    TileOption(value: LockScreenStart.lyrics, title: L("Cover und Songtext", "Cover and lyrics"), symbol: "quote.bubble"),
                ])
                .disabled(!settings.lockScreenWidgets)
                ValueSlider(title: L("Helligkeit des Glases", "Glass brightness"),
                            value: Binding(get: { settings.lockScreenTransparency * 100 },
                                           set: { settings.lockScreenTransparency = $0 / 100 }),
                            range: 0...100, step: 5, format: "%.0f %%")
                    .disabled(!settings.lockScreenWidgets)
                Picker(L("Hintergrund beim großen Cover", "Background with large cover"), selection: $settings.lockScreenBackdrop) {
                    Text(L("Dunkel, vom Cover getönt", "Dark, tinted by the cover")).tag(LockScreenBackdrop.tinted)
                    Text(L("Cover, unscharf", "Cover, blurred")).tag(LockScreenBackdrop.coverBlurred)
                    Text(L("Cover, scharf", "Cover, sharp")).tag(LockScreenBackdrop.cover)
                }
                .disabled(!settings.lockScreenWidgets)
            } footer: {
                note("Nur solange etwas läuft. Startet mit der gewählten Ansicht; ein Klick aufs Cover wechselt zwischen klein und groß, der Songtext-Knopf blendet die Lyrics ein und aus. Nutzt eine nicht dokumentierte Systemschnittstelle und kann nach macOS-Updates ausfallen.",
                     "Only while something plays. Starts with the chosen view; clicking the cover switches between small and large, the lyrics button shows and hides the lyrics. Uses an undocumented system interface and may break after macOS updates.")
            }
            Section {
                Toggle(L("Als Bildschirmschoner, wenn Musik läuft", "As screen saver while music plays"), isOn: $settings.screenSaverEnabled)
                Picker(L("Starten nach", "Start after"), selection: $settings.screenSaverDelay) {
                    ForEach([1.0, 2, 5, 10, 15, 30], id: \.self) { minutes in
                        Text(L("\(Int(minutes)) Min.", "\(Int(minutes)) min")).tag(minutes)
                    }
                }
                .disabled(!settings.screenSaverEnabled)
                Toggle(L("Songtext zeigen", "Show lyrics"), isOn: $settings.screenSaverLyrics)
                    .disabled(!settings.screenSaverEnabled)
                Button(L("Vorschau", "Preview")) { appDelegate.screenSaver?.show() }
            } header: {
                Text(L("Bildschirmschoner", "Screen saver"))
            } footer: {
                note("Großes Cover, Uhr und Songtext auf dem vom Cover getönten Hintergrund, wenn du so lange nichts tust und Musik läuft. Eine Taste, ein Klick oder eine Mausbewegung beendet ihn. Bei Videos und im Vollbild bleibt er aus. Stell den macOS-Bildschirmschoner auf eine längere Zeit oder „Nie“, sonst kommt dieser zuerst.",
                     "Large cover, clock and lyrics on the cover-tinted background when you have been idle that long and music plays. A key, click or mouse move ends it. It stays off for videos and in full screen. Set the macOS screen saver to a longer time or “Never”, otherwise that one starts first.")
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    let appDelegate: AppDelegate
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var locationGranted = Permissions.locationGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Willkommen bei Horizon Notch", "Welcome to Horizon Notch"))
                        .font(.title3.weight(.semibold))
                    Text(L("Fahre mit dem Mauszeiger auf die Notch, um die Island zu öffnen. Berechtigungen fragt die App nur für Funktionen an, die du nutzt.",
                           "Move the pointer onto the notch to open the island. The app only asks for permissions that the features you use need."))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section(L("Berechtigungen", "Permissions")) {
                PermissionRow(
                    title: L("Bedienungshilfen", "Accessibility"),
                    detail: L("Damit Lautstärke- und Helligkeitstasten die Anzeige in der Notch statt der System-Anzeige zeigen.",
                              "Lets the volume and brightness keys show their overlay in the notch instead of the system HUD."),
                    granted: accessibility,
                    action: {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    })
                PermissionRow(
                    title: L("Kalender", "Calendar"),
                    detail: L("Für den nächsten Termin und den Countdown bis zum Meeting.",
                              "For your next event and the countdown to a meeting."),
                    granted: calendarGranted,
                    action: {
                        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                            appDelegate.calendar.requestAccess()
                        } else {
                            Permissions.openPrivacySettings("Privacy_Calendars")
                        }
                    })
                PermissionRow(
                    title: L("Standort", "Location"),
                    detail: L("Für das Wetter vor Ort. Alternativ suchst du unter Wetter einen Ort.",
                              "For local weather. Alternatively search for a place under Weather."),
                    granted: locationGranted,
                    action: {
                        if CLLocationManager().authorizationStatus == .notDetermined {
                            appDelegate.weather.service.activate()
                        } else {
                            Permissions.openPrivacySettings("Privacy_LocationServices")
                        }
                    })
                PermissionRow(
                    title: L("Kamera & Mikrofon", "Camera & Microphone"),
                    detail: L("Die Anzeige liest nur, ob ein Gerät benutzt wird – ohne Berechtigung und ohne selbst aufzunehmen.",
                              "The indicator only reads whether a device is in use – no permission, and it never records itself."),
                    granted: true,
                    action: nil)
                PermissionRow(
                    title: L("Jetzt läuft", "Now Playing"),
                    detail: L("Funktioniert ohne Berechtigung für Musik, Spotify und Browser.",
                              "Works without a permission for Music, Spotify and browsers."),
                    granted: true,
                    action: nil)
            }
        }
        .onReceive(timer) { _ in
            let now = Permissions.accessibilityGranted
            if now != accessibility {
                accessibility = now
                appDelegate.permissionsChanged()
            }
            calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            locationGranted = Permissions.locationGranted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted, let action {
                Button(L("Erlauben …", "Allow …"), action: action)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - About

/// Automatic updates from GitHub, and a button to look right now.
private struct UpdateSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section {
            Toggle(L("Automatisch nach Updates suchen", "Check for updates automatically"), isOn: $settings.autoUpdateCheck)
            LabeledContent(L("Version \(Updater.currentVersion) (Build \(Updater.currentBuild))",
                             "Version \(Updater.currentVersion) (build \(Updater.currentBuild))")) {
                HStack {
                    statusText
                    Button(L("Jetzt suchen", "Check now")) { updater.check(userInitiated: true) }
                        .disabled(updater.status == .checking || updater.status == .downloading || updater.status == .installing)
                }
            }
        } header: {
            Text(L("Updates", "Updates"))
        } footer: {
            note("Neue Versionen kommen direkt von GitHub. Ein Klick auf „Installieren“ lädt sie, ersetzt die App und startet sie neu – kein DMG nötig.",
                 "New versions come straight from GitHub. “Install” downloads one, replaces the app and restarts it – no DMG needed.")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.status {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text(L("Aktuell", "Up to date")).foregroundStyle(.secondary)
        case .available(let release): Text(L("Build \(release.build) verfügbar", "Build \(release.build) available")).foregroundStyle(.orange)
        case .downloading: Text(L("Lädt …", "Downloading …")).foregroundStyle(.secondary)
        case .installing: Text(L("Installiert …", "Installing …")).foregroundStyle(.secondary)
        case .failed: Text(L("Fehlgeschlagen", "Failed")).foregroundStyle(.red)
        case .idle: EmptyView()
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Horizon Notch").font(.title2.weight(.semibold))
                        Text("Version \(Updater.currentVersion) (Build \(Updater.currentBuild))")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            UpdateSection()
        }
    }
}
