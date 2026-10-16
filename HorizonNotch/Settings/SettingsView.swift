import AppKit
import Combine
import CoreLocation
import EventKit
import SwiftUI

struct SettingsView: View {
    let appDelegate: AppDelegate
    @ObservedObject var selection: SettingsSelection
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.tab) {
                Section(L("App", "App")) {
                    item(.general, L("Allgemein", "General"), "gearshape")
                    item(.appearance, L("Darstellung", "Appearance"), "paintbrush")
                    item(.behavior, L("Verhalten", "Behaviour"), "cursorarrow.motionlines")
                }
                Section(L("Island", "Island")) {
                    item(.tabs, L("Reiter", "Tabs"), "rectangle.split.3x1")
                    item(.modules, L("Module", "Modules"), "square.grid.2x2")
                }
                Section(L("Funktionen", "Features")) {
                    item(.music, L("Musik", "Music"), "music.note")
                    item(.lyrics, L("Songtext", "Lyrics"), "quote.bubble")
                    item(.hud, L("Lautstärke & Helligkeit", "Volume & Brightness"), "speaker.wave.2")
                    item(.battery, L("Akku & Energie", "Battery & Power"), "battery.75percent")
                    item(.calendar, L("Kalender", "Calendar"), "calendar")
                    item(.weather, L("Wetter", "Weather"), "cloud.sun")
                    item(.shelf, L("Ablage", "Shelf"), "tray.full")
                    item(.connectivity, L("Verbindungen", "Connectivity"), "dot.radiowaves.left.and.right")
                    item(.notifications, L("Benachrichtigungen", "Notifications"), "bell.badge")
                    item(.downloads, L("Downloads", "Downloads"), "arrow.down.circle")
                    item(.claude, "Claude Code", "sparkle")
                    item(.lockScreen, L("Sperrbildschirm", "Lock Screen"), "lock.display")
                }
                Section(L("System", "System")) {
                    item(.permissions, L("Berechtigungen", "Permissions"), "lock.shield")
                    item(.about, L("Über", "About"), "info.circle")
                }
            }
            .navigationSplitViewColumnWidth(210)
        } detail: {
            Group {
                switch selection.tab {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .behavior: BehaviorSettings()
                case .tabs: TabSettings(coordinator: appDelegate.coordinator)
                case .modules: ModuleSettings(coordinator: appDelegate.coordinator)
                case .music: MusicSettings()
                case .lyrics: LyricsSettings()
                case .hud: HUDSettings()
                case .battery: BatterySettings()
                case .downloads: DownloadSettings()
                case .claude: ClaudeSettings()
                case .calendar: CalendarSettings()
                case .weather: WeatherSettings()
                case .shelf: ShelfSettings()
                case .connectivity: ConnectivitySettings()
                case .notifications: NotificationSettings()
                case .lockScreen: LockScreenSettings()
                case .permissions: PermissionSettings(appDelegate: appDelegate)
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    private func item(_ tab: SettingsTab, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).tag(tab)
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
        Form {
            Section {
                Toggle(L("Bei der Anmeldung starten", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in LaunchAtLogin.set(value) }
                Picker(L("Sprache", "Language"), selection: $settings.language) {
                    Text(L("Systemsprache", "System language")).tag(AppLanguage.system)
                    Text("Deutsch").tag(AppLanguage.de)
                    Text("English").tag(AppLanguage.en)
                }
            }
            Section {
                Picker(L("Bildschirm", "Display"), selection: $settings.displayID) {
                    Text(L("Automatisch", "Automatic")).tag(UInt32(0))
                    ForEach(NSScreen.screens, id: \.displayID) { screen in
                        Text(screen.localizedName + (screen.hasNotch ? " (Notch)" : "")).tag(screen.displayID)
                    }
                }
            } footer: {
                note("Automatisch nimmt den Bildschirm mit Notch, sonst den Hauptbildschirm. Ohne Notch erscheint eine schwebende Kapsel.",
                     "Automatic picks the display with a notch, otherwise the main display. Without a notch a floating capsule appears.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Stil der Island", "Island style"), selection: $settings.appearance) {
                    Text(L("Schwarz", "Black")).tag(IslandAppearance.black)
                    Text(L("Glas", "Glass")).tag(IslandAppearance.glass)
                    Text(L("Farbig", "Tinted")).tag(IslandAppearance.tinted)
                }
                .pickerStyle(.segmented)
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
                note("Glas nutzt ab macOS 26 Liquid Glass, davor ein Material. Geschlossen ist die Island immer schwarz, damit sie mit der Notch verschmilzt.",
                     "Glass uses Liquid Glass on macOS 26+, a material before. Closed, the island is always black so it blends with the notch.")
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
                }
                .pickerStyle(.segmented)
            }
            Section {
                ValueSlider(title: L("Animationstempo", "Animation speed"), value: $settings.animationSpeed,
                            range: 0.5...1.8, step: 0.1, format: "%.1f×")
            }
        }
        .formStyle(.grouped)
    }
}

private func hexBinding(_ key: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<Color> {
    Binding(get: { Color(hex: AppSettings.shared[keyPath: key]) ?? .white },
            set: { AppSettings.shared[keyPath: key] = $0.hexString })
}

private struct BehaviorSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

// MARK: - Island

private struct ModuleRow: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

/// Order and visibility of the tabs at the top of the open island.
private struct TabSettings: View {
    let coordinator: NotchCoordinator
    @ObservedObject private var settings = AppSettings.shared

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
        Form {
            Section {
                List {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Image(systemName: row.symbol)
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            Toggle(row.title, isOn: Binding(
                                get: { !settings.hiddenTabs.contains(row.id) },
                                set: { visible in
                                    if visible { settings.hiddenTabs.remove(row.id) } else { settings.hiddenTabs.insert(row.id) }
                                }))
                        }
                    }
                    .onMove { from, to in
                        var ids = rows.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        settings.moduleOrder = ids
                    }
                }
                .frame(minHeight: 230)
            } header: {
                Text(L("Reiter", "Tabs"))
            } footer: {
                note("Ziehen zum Sortieren, Schalter blendet einen Reiter aus. Ausgeblendete Module laufen weiter, z. B. zeigt ein laufender Timer trotzdem seinen Countdown neben der Notch.",
                     "Drag to reorder; the switch hides a tab. Hidden modules keep working, e.g. a running timer still shows its countdown next to the notch.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Switches whole modules on or off (tab and live activity).
private struct ModuleSettings: View {
    let coordinator: NotchCoordinator
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

// MARK: - Features

private struct MusicSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Wischen im Musik-Reiter", "Swipe on the music tab"), selection: $settings.musicGesture) {
                    Text(L("Titel wechseln", "Change track")).tag(MusicGesture.track)
                    Text(L("10 s spulen", "Seek 10 s")).tag(MusicGesture.seek)
                    Text(L("Aus", "Off")).tag(MusicGesture.off)
                }
            } header: {
                Text(L("Gesten", "Gestures"))
            } footer: {
                note("Mit zwei Fingern seitlich wischen, während der Musik-Reiter offen ist. Nach links = weiter, nach rechts = zurück; mit Trackpad-Klick.",
                     "Swipe sideways with two fingers while the music tab is open. Left = forward, right = back; with a trackpad click.")
            }
            Section(L("Player", "Player")) {
                Toggle(L("Quelle unter dem Cover anzeigen", "Show the source below the cover"), isOn: $settings.showSource)
                Toggle(L("Albumfarbe für Schein, Balken und Hervorhebungen", "Album colour for glow, bars and highlights"),
                       isOn: $settings.albumTint)
                Toggle(L("Audio-Visualizer", "Audio visualizer"), isOn: $settings.showVisualizer)
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
        .formStyle(.grouped)
    }
}

private struct LyricsSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Songtext-Feld neben dem Player", "Lyrics field next to the player"), isOn: $settings.showLyrics)
                Toggle(L("Große Schrift", "Large text"), isOn: $settings.lyricsLarge)
                    .disabled(!settings.showLyrics)
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
        .formStyle(.grouped)
    }
}

private struct HUDSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("System-Anzeige ersetzen", "Replace the system overlay"), isOn: $settings.replaceSystemHUD)
            } footer: {
                note("Gilt für Lautstärke, Stummschaltung, Bildschirmhelligkeit und Tastaturlicht. Braucht die Bedienungshilfen-Berechtigung.",
                     "Covers volume, mute, display brightness and keyboard light. Needs the Accessibility permission.")
            }
            Section(L("Darstellung", "Look")) {
                Picker(L("Ort", "Position"), selection: $settings.hudStyle) {
                    Text(L("In der Notch", "In the notch")).tag(HUDStyle.notch)
                    Text(L("Balken am linken Rand", "Bar at the left edge")).tag(HUDStyle.sideBar)
                }
                .pickerStyle(.radioGroup)
                Toggle(L("Prozentzahl anzeigen", "Show percentage"), isOn: $settings.hudShowPercent)
                    .disabled(settings.hudStyle != .notch)
                Picker(L("Balkenfarbe", "Bar colour"), selection: $settings.hudBarColor) {
                    Text(L("Weiß", "White")).tag(HUDBarColor.white)
                    Text(L("Farbig", "Coloured")).tag(HUDBarColor.colorful)
                }
                .pickerStyle(.segmented)
                note("Farbig: Lautstärke in der Akzentfarbe, Helligkeit gelb, Tastaturlicht blau.",
                     "Coloured: volume in the accent colour, brightness yellow, keyboard light blue.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalendarSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L("Ansicht", "View")) {
                Stepper(value: $settings.calendarDaysAhead, in: 3...60) {
                    Text(L("Tage voraus in der Datumsleiste: \(settings.calendarDaysAhead)",
                           "Days ahead in the date strip: \(settings.calendarDaysAhead)"))
                }
                Toggle(L("Ganztägige Termine anzeigen", "Show all-day events"), isOn: $settings.calendarShowAllDay)
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
        .formStyle(.grouped)
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
        Form {
            Section {
                Toggle(L("Aktuellen Standort verwenden", "Use current location"), isOn: $settings.weatherUsesLocation)
                if !settings.weatherUsesLocation {
                    PlaceSearch()
                }
            } footer: {
                note("Wetterdaten von Open-Meteo, ohne Konto.", "Weather data from Open-Meteo, no account needed.")
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
        .formStyle(.grouped)
    }
}

private struct ShelfSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

private struct ConnectivitySettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Alle Bluetooth-Geräte und AirPods-Akku", "All Bluetooth devices and AirPods battery"),
                       isOn: $settings.connectivityAllBluetooth)
                Toggle(L("Fokus ein/aus", "Focus on/off"), isOn: $settings.connectivityFocus)
            } footer: {
                note("Kopfhörer und WLAN-Wechsel erscheinen immer, ohne Berechtigung. Die beiden Optionen fragen beim Einschalten nach Bluetooth bzw. dem Fokus-Status.",
                     "Headphones and Wi-Fi changes always show, without a permission. The two options ask for Bluetooth or Focus status when switched on.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Fertige Downloads", "Finished downloads"), isOn: $settings.notifyDownloads)
            } footer: {
                note("Fragt beim Einschalten nach Zugriff auf den Downloads-Ordner. Mitteilungen anderer Apps gibt macOS nicht an Dritt-Apps weiter.",
                     "Asks for access to the Downloads folder when switched on. macOS does not pass other apps' notifications to third-party apps.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct BatterySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Form {
            Section(L("Anzeige", "Display")) {
                Toggle(L("Akku oben rechts in der geöffneten Island", "Battery at the top right of the open island"),
                       isOn: $settings.batteryInHeader)
                Toggle(L("Prozent anzeigen", "Show percentage"), isOn: $settings.batteryShowPercent)
                    .disabled(!settings.batteryInHeader)
            }
            Section {
                Toggle(L("Wach bleiben, auch zugeklappt", "Stay awake, also with the lid closed"), isOn: Binding(
                    get: { awake.isOn }, set: { awake.set($0) }))
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
                note("Bleibt an, bis du es ausschaltest – auch nach einem Neustart. Dafür nutzt macOS „pmset disablesleep“. Nur beim allerersten Mal fragt macOS nach deinem Passwort; danach darf Horizon Notch genau diesen einen Befehl ohne Passwort ausführen (wie Amphetamine Enhancer). Achtung: Zugeklappt in der Tasche kann der Mac warm werden.",
                     "Stays on until you switch it off – also after a restart. macOS uses “pmset disablesleep” for this. Only the very first time macOS asks for your password; after that Horizon Notch may run exactly this one command without a password (like Amphetamine Enhancer). Careful: closed in a bag the Mac can get warm.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Laufende und fertige Downloads anzeigen", "Show running and finished downloads"), isOn: $settings.notifyDownloads)
            } footer: {
                note("Zeigt Fortschritt neben der Notch, solange Safari, Chrome & Co. in den Downloads-Ordner laden, und meldet fertige Dateien. Fragt beim Einschalten nach Zugriff auf den Downloads-Ordner.",
                     "Shows progress next to the notch while Safari, Chrome & co. download into the Downloads folder, and reports finished files. Asks for access to the Downloads folder when switched on.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClaudeSettings: View {
    @State private var installed = ClaudeHooks.isInstalled
    @State private var error: String?

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

private struct LockScreenSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Musik-Player auf dem Sperrbildschirm", "Music player on the lock screen"), isOn: $settings.lockScreenWidgets)
            } footer: {
                note("Wie beim iPhone: Cover, Titel, Fortschritt, Wiedergabe-Tasten und Lautstärke – nur solange etwas läuft. Nutzt eine nicht dokumentierte Systemschnittstelle und kann nach macOS-Updates ausfallen.",
                     "Like on the iPhone: cover, title, progress, playback buttons and volume – only while something plays. Uses an undocumented system interface and may break after macOS updates.")
            }
        }
        .formStyle(.grouped)
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
        Form {
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
        .formStyle(.grouped)
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

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Horizon Notch").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
