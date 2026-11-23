import AppKit
import SwiftUI

/// Settings → Light: the strip, the two automatic options, and the user's
/// own moods (name, symbol, white or colour, brightness).
struct LightSettings: View {
    @ObservedObject private var light = HueBluetoothLight.shared
    @ObservedObject private var moods = LightMoods.shared
    @AppStorage("lightOffOnLock") private var offOnLock = false
    @AppStorage("lightCoverSync") private var coverSync = false

    private static let symbols = ["sparkles", "moon.fill", "sun.max.fill", "book.fill", "leaf.fill", "film.fill",
                                  "gamecontroller.fill", "bed.double.fill", "cup.and.saucer.fill", "heart.fill",
                                  "flame.fill", "snowflake", "party.popper.fill", "laptopcomputer"]

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
            } header: {
                Text(L("Hue-Licht", "Hue light"))
            } footer: {
                Text(L("Zum Koppeln in der Hue-App unter Einstellungen → Sprachassistenten → Amazon Alexa „Auffindbar machen“ tippen.",
                       "To pair, tap “Make discoverable” in the Hue app under Settings → Voice assistants → Amazon Alexa."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($moods.items) { $mood in
                    SceneRow(mood: $mood, symbols: Self.symbols) {
                        moods.items.removeAll { $0.id == mood.id }
                    }
                }
                .onMove { moods.items.move(fromOffsets: $0, toOffset: $1) }
                HStack(spacing: 14) {
                    Button {
                        guard let kind = light.current else { return }
                        moods.items.append(LightMood(name: L("Szene \(moods.items.count + 1)", "Scene \(moods.items.count + 1)"),
                                                     symbol: "sparkles", kind: kind,
                                                     brightness: max(0.05, light.brightness)))
                    } label: {
                        Label(L("Aktuelles Licht als Szene speichern", "Save current light as scene"),
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(light.current == nil)
                    Button {
                        moods.items.append(LightMood(name: L("Neue Szene", "New scene"), symbol: "sparkles",
                                                     kind: .color(hex: "#3A7BFF"), brightness: 0.6))
                    } label: {
                        Label(L("Leere Szene", "Empty scene"), systemImage: "plus")
                    }
                    Spacer()
                    if !moods.items.contains(where: { LightMood.presets.map(\.id).contains($0.id) }) {
                        Button(L("Standard-Szenen zurück", "Restore defaults")) {
                            moods.items.insert(contentsOf: LightMood.presets, at: 0)
                        }
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text(L("Lichtszenen", "Light scenes"))
            } footer: {
                Text(L("Sie erscheinen in dieser Reihenfolge im Licht-Tab. „Aktuelles Licht speichern“ übernimmt Farbe oder Weißton und Helligkeit, wie der Streifen gerade leuchtet.",
                       "They appear on the Light tab in this order. “Save current light” takes the colour or white and the brightness the strip shows right now."))
                    .font(.caption).foregroundStyle(.secondary)
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

/// One scene: swatch, symbol and name; opens to edit, with delete.
private struct SceneRow: View {
    @Binding var mood: LightMood
    let symbols: [String]
    let delete: () -> Void
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            MoodEditor(mood: $mood, symbols: symbols, delete: delete)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: mood.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 18)
                Image(systemName: mood.symbol).frame(width: 18)
                Text(mood.name)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let level = "\(Int((mood.brightness * 100).rounded())) %"
        switch mood.kind {
        case .white(let kelvin): return "\(Int(kelvin)) K · \(level)"
        case .color: return L("Farbe", "Colour") + " · " + level
        case .cover: return L("Cover-Farbe", "Cover colour") + " · " + level
        }
    }
}

private struct MoodEditor: View {
    @Binding var mood: LightMood
    let symbols: [String]
    let delete: () -> Void

    private var isWhite: Bool { if case .white = mood.kind { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(symbols, id: \.self) { symbol in
                        Button { mood.symbol = symbol } label: { Image(systemName: symbol) }
                    }
                } label: {
                    Image(systemName: mood.symbol)
                }
                .fixedSize()
                TextField(L("Name", "Name"), text: $mood.name)
                if mood.kind != .cover {
                    Picker("", selection: Binding(get: { isWhite }, set: { white in
                        mood.kind = white ? .white(kelvin: 3000) : .color(hex: "#3A7BFF")
                    })) {
                        Text(L("Weiß", "White")).tag(true)
                        Text(L("Farbe", "Colour")).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Button(role: .destructive, action: delete) { Label(L("Löschen", "Delete"), systemImage: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                switch mood.kind {
                case .white(let kelvin):
                    Image(systemName: "thermometer.medium").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { kelvin }, set: { mood.kind = .white(kelvin: $0) }), in: 2200...6500)
                    Text("\(Int(kelvin)) K").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                case .color(let hex):
                    // Same colour field as in the island, no extra window.
                    let parts = SpectrumPicker.components(of: NSColor(hex: hex) ?? .systemBlue)
                    SpectrumPicker(hue: Binding(get: { parts.hue }, set: { _ in }),
                                   saturation: Binding(get: { parts.saturation }, set: { _ in }),
                                   cornerRadius: 7) { color in mood.kind = .color(hex: color.hexString) }
                        .frame(height: 34)
                case .cover:
                    EmptyView()
                }
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                Slider(value: $mood.brightness, in: 0.05...1)
                Text("\(Int((mood.brightness * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}
