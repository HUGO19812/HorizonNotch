import AppKit
import SwiftUI

/// Settings → Light: the strip, the automatic options, and the light
/// scenes – each a row with edit and delete, edited in a sheet with a live
/// preview, and one "New scene" button.
struct LightSettings: View {
    @ObservedObject private var light = HueBluetoothLight.shared
    @ObservedObject private var moods = LightMoods.shared
    @AppStorage("lightOffOnLock") private var offOnLock = false
    @AppStorage("lightCoverSync") private var coverSync = false
    @AppStorage("lightClaude") private var claudeLight = true
    /// The scene in the editor; `isNew` decides whether "Done" appends it.
    @State private var editing: (mood: LightMood, isNew: Bool)?

    var body: some View {
        // Only the sections: the settings window puts them in one form.
        Group {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(light.isPaired ? light.name : L("Kein Licht verbunden", "No light connected"))
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if light.isPaired {
                        Button(L("Vergessen", "Forget"), role: .destructive) { light.forget() }
                    } else {
                        Button(light.phase == .searching ? L("Suche …", "Searching …") : L("Suchen", "Search")) { light.search() }
                            .disabled(light.phase == .searching)
                    }
                }
                Toggle(L("Beim Sperren ausschalten", "Switch off when the Mac locks"), isOn: $offOnLock)
                Toggle(L("Farbe des Covers folgen", "Follow the cover's colour"), isOn: $coverSync)
                Toggle(L("Claude-Licht: pulsiert, wenn Claude auf dich wartet, blinkt grün, wenn fertig",
                         "Claude light: pulses while Claude waits for you, flashes green when done"), isOn: $claudeLight)
            } header: {
                Text(L("Hue-Licht", "Hue light"))
            } footer: {
                Text(L("Zum Koppeln in der Hue-App unter Einstellungen → Sprachassistenten → Amazon Alexa „Auffindbar machen“ tippen.",
                       "To pair, tap “Make discoverable” in the Hue app under Settings → Voice assistants → Amazon Alexa."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(moods.items) { mood in
                    SceneRow(mood: mood,
                             edit: { editing = (mood, false) },
                             delete: { withAnimation { moods.items.removeAll { $0.id == mood.id } } })
                }
                .onMove { moods.items.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Menu {
                        Button {
                            guard let kind = light.current else { return }
                            editing = (LightMood(name: L("Neue Szene", "New scene"), symbol: "sparkles", kind: kind,
                                                 brightness: max(0.05, light.brightness)), true)
                        } label: {
                            Label(L("Aktuelles Licht übernehmen", "From the current light"), systemImage: "lightbulb.led.wide")
                        }
                        .disabled(light.current == nil)
                        Button {
                            editing = (LightMood(name: L("Neue Szene", "New scene"), symbol: "sparkles",
                                                 kind: .white(kelvin: 3000), brightness: 0.6), true)
                        } label: {
                            Label(L("Leer beginnen", "Start empty"), systemImage: "square.dashed")
                        }
                    } label: {
                        Label(L("Neue Szene", "New scene"), systemImage: "plus")
                    }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                    Spacer()
                    if !moods.items.contains(where: { LightMood.presets.map(\.id).contains($0.id) }) {
                        Button(L("Standard-Szenen zurückholen", "Restore default scenes")) {
                            moods.items.insert(contentsOf: LightMood.presets, at: 0)
                        }
                        .buttonStyle(.link)
                    }
                }
            } header: {
                Text(L("Lichtszenen", "Light scenes"))
            } footer: {
                Text(L("In dieser Reihenfolge erscheinen sie im Licht-Tab; zum Umsortieren ziehen.",
                       "They appear on the Light tab in this order; drag to reorder."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                SceneEditor(mood: editing.mood, isNew: editing.isNew) { saved in
                    if let saved {
                        if let index = moods.items.firstIndex(where: { $0.id == saved.id }) {
                            moods.items[index] = saved
                        } else {
                            moods.items.append(saved)
                        }
                    }
                    self.editing = nil
                }
            }
        }
    }

    private var status: String {
        switch light.phase {
        case .bluetoothOff: return L("Bluetooth ist aus", "Bluetooth is off")
        case .unauthorized: return L("Bluetooth nicht erlaubt", "Bluetooth not allowed")
        case .searching: return L("Sucht nach einem Hue-Licht …", "Looking for a Hue light …")
        default: return light.reachable ? L("Erreichbar", "Reachable") : (light.isPaired ? L("Gekoppelt", "Paired") : "")
        }
    }
}

/// Swatch, symbol, name and a short summary; edit and delete beside it.
private struct SceneRow: View {
    let mood: LightMood
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: mood.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: mood.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
            }
            .frame(width: 32, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(mood.name)
                Text(mood.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(L("Bearbeiten", "Edit"))
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(L("Löschen", "Delete"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

extension LightMood {
    var summary: String {
        let level = "\(Int((brightness * 100).rounded())) %"
        switch kind {
        case .white(let kelvin): return L("Weiß", "White") + " · \(Int(kelvin)) K · " + level
        case .color: return L("Farbe", "Colour") + " · " + level
        case .cover: return L("Farbe des Covers", "Cover colour") + " · " + level
        }
    }
}

/// The scene editor: a large live preview on top, then name, symbol, white
/// or colour, brightness. "Try on the strip" shows it for real.
private struct SceneEditor: View {
    @State var mood: LightMood
    let isNew: Bool
    let finish: (LightMood?) -> Void
    @State private var hue = 0.6
    @State private var saturation = 0.8

    private static let symbols = ["sparkles", "sun.max.fill", "moon.fill", "book.fill", "leaf.fill", "film.fill",
                                  "gamecontroller.fill", "bed.double.fill", "cup.and.saucer.fill", "heart.fill",
                                  "flame.fill", "snowflake", "party.popper.fill", "laptopcomputer", "music.note",
                                  "figure.mind.and.body"]

    private var isWhite: Bool { if case .white = mood.kind { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            preview
            Form {
                TextField(L("Name", "Name"), text: $mood.name)
                LabeledContent(L("Symbol", "Symbol")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8), spacing: 6) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button { mood.symbol = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(mood.symbol == symbol ? Color.accentColor : Color.primary.opacity(0.08)))
                                    .foregroundStyle(mood.symbol == symbol ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if mood.kind != .cover {
                    Picker(L("Licht", "Light"), selection: Binding(get: { isWhite }, set: { white in
                        mood.kind = white ? .white(kelvin: 3000) : .color(hex: SpectrumPicker.color(hue: hue, saturation: saturation).hexString)
                    })) {
                        Text(L("Weiß", "White")).tag(true)
                        Text(L("Farbe", "Colour")).tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                switch mood.kind {
                case .white(let kelvin):
                    LabeledContent(L("Weißton", "White")) {
                        HStack {
                            Slider(value: Binding(get: { kelvin }, set: { mood.kind = .white(kelvin: ($0 / 50).rounded() * 50) }),
                                   in: 2200...6500)
                            Text("\(Int(kelvin)) K").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                case .color:
                    LabeledContent(L("Farbe", "Colour")) {
                        SpectrumPicker(hue: $hue, saturation: $saturation, cornerRadius: 8) { color in
                            mood.kind = .color(hex: color.hexString)
                        }
                        .frame(height: 70)
                    }
                case .cover:
                    LabeledContent(L("Farbe", "Colour"), value: L("Folgt dem laufenden Cover", "Follows the playing cover"))
                }
                LabeledContent(L("Helligkeit", "Brightness")) {
                    HStack {
                        Slider(value: $mood.brightness, in: 0.05...1)
                        Text("\(Int((mood.brightness * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(L("Am Streifen testen", "Try on the strip")) { tryOnStrip() }
                    .disabled(!HueBluetoothLight.shared.isPaired)
                Spacer()
                Button(L("Abbrechen", "Cancel"), role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L("Hinzufügen", "Add") : L("Fertig", "Done")) { finish(mood) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mood.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear {
            if case .color(let hex) = mood.kind, let color = NSColor(hex: hex) {
                (hue, saturation) = SpectrumPicker.components(of: color)
            }
        }
    }

    /// The scene as it will look on the Light tab, large.
    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: mood.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: (mood.colors.last ?? .clear).opacity(0.45), radius: 18, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: mood.symbol).font(.system(size: 22, weight: .bold))
                Text(mood.name.isEmpty ? " " : mood.name).font(.system(size: 18, weight: .bold))
                Text(mood.summary).font(.system(size: 11, weight: .medium)).opacity(0.75)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .padding(16)
        }
        .frame(height: 120)
        .padding([.horizontal, .top], 16)
        .animation(.easeInOut(duration: 0.2), value: mood)
    }

    private func tryOnStrip() {
        let light = HueBluetoothLight.shared
        light.setBrightness(mood.brightness)
        switch mood.kind {
        case .white(let kelvin): light.setWhite(kelvin: kelvin)
        case .color(let hex): if let color = NSColor(hex: hex) { light.setColor(color) }
        case .cover: break
        }
    }
}
