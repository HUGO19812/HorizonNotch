import AppKit
import Combine
import SwiftUI

/// A light mood: a name, a symbol, a white or a colour and a brightness.
/// "Cover" is special: it follows the playing cover's colour.
struct LightMood: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case white(kelvin: Double)
        case color(hex: String)
        case cover
    }

    var id = UUID()
    var name: String
    var symbol: String
    var kind: Kind
    /// 0…1.
    var brightness: Double

    var colors: [Color] {
        switch kind {
        case .white(let kelvin):
            let base = HueBluetoothLight.whiteColor(kelvin: kelvin)
            return [base.opacity(0.85), base]
        case .color(let hex):
            let base = Color(hex: hex) ?? .orange
            return [base.opacity(0.8), base]
        case .cover:
            return [Color(red: 0.85, green: 0.65, blue: 0.55), Color(red: 0.6, green: 0.4, blue: 0.35)]
        }
    }

    static let presets: [LightMood] = [
        LightMood(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!, name: L("Lesen", "Reading"),
                  symbol: "book.fill", kind: .white(kelvin: 4000), brightness: 0.85),
        LightMood(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!, name: L("Entspannen", "Relax"),
                  symbol: "leaf.fill", kind: .color(hex: "#FF6A33"), brightness: 0.45),
        LightMood(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!, name: "Film",
                  symbol: "film.fill", kind: .color(hex: "#5A3FE6"), brightness: 0.2),
        LightMood(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!, name: "Cover",
                  symbol: "music.note", kind: .cover, brightness: 0.6),
    ]
}

/// The light scenes shown on the tab: the four presets to start with, then
/// whatever the user saves, edits or deletes in Settings → Light. Stored as
/// JSON.
final class LightMoods: ObservableObject {
    static let shared = LightMoods()
    private static let key = "lightScenes"

    @Published var items: [LightMood] {
        didSet { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }

    var all: [LightMood] { items }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([LightMood].self, from: data) {
            items = saved
        } else {
            // First start, or moods from the version before scenes.
            let old = UserDefaults.standard.data(forKey: "lightMoods")
                .flatMap { try? JSONDecoder().decode([LightMood].self, from: $0) } ?? []
            items = LightMood.presets + old
        }
    }
}

/// The Hue light strip on its own page (see LightPage).
final class LightModule: NotchModule {
    let id = "light"
    var title: String { L("Licht", "Light") }
    let symbol = "lightbulb.led.wide.fill"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    let light = HueBluetoothLight.shared
    let moods = LightMoods.shared
    private let nowPlaying: NowPlayingService
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// Switched off because the Mac locked; switched on again on unlock.
    private var offForLock = false

    @AppStorage("lightCoverSync") var coverSync = false
    @AppStorage("lightOffOnLock") var offOnLock = false
    @AppStorage("lightMoodID") var activeMoodID = ""
    /// Claude light: pulses in Claude's orange while Claude waits for you,
    /// flashes green when it's done.
    @AppStorage("lightClaude") var claudeLight = true

    private let claude: ClaudeCodeMonitor
    private var beforeEffect: HueBluetoothLight.Snapshot?
    private var pulseTimer: Timer?
    private var pulseHigh = false
    private var flashWork: DispatchWorkItem?
    private static let claudeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    var headerInfo: HeaderInfo? {
        guard light.isPaired, light.hasState else { return nil }
        return .text(light.isOn ? "\(Int((light.brightness * 100).rounded())) %" : L("Aus", "Off"))
    }

    init(nowPlaying: NowPlayingService, claude: ClaudeCodeMonitor) {
        self.nowPlaying = nowPlaying
        self.claude = claude
        claude.$sessions
            .map { sessions in sessions.contains { if case .waiting = $0.activity { return true }; return false } }
            .removeDuplicates()
            .sink { [weak self] waiting in DispatchQueue.main.async { self?.claudeWaiting(waiting) } }
            .store(in: &subscriptions)
        claude.turnFinished
            .sink { [weak self] in DispatchQueue.main.async { self?.claudeDone() } }
            .store(in: &subscriptions)
        light.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        moods.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        nowPlaying.$accent.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.followCover() } }
            .store(in: &subscriptions)
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.locked() })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                                            queue: .main) { [weak self] _ in self?.unlocked() })
        light.start()
    }

    func apply(_ mood: LightMood) {
        activeMoodID = mood.id.uuidString
        coverSync = mood.kind == .cover
        light.setBrightness(mood.brightness)
        switch mood.kind {
        case .white(let kelvin): light.setWhite(kelvin: kelvin)
        case .color(let hex): if let color = NSColor(hex: hex) { light.setColor(color) }
        case .cover: followCover(force: true)
        }
    }

    /// A colour from the free colour choice.
    func applyFree(_ color: NSColor) {
        activeMoodID = "free"
        coverSync = false
        light.setColor(color)
    }

    /// The cover's colour, when that mood is on and the light is on.
    private func followCover(force: Bool = false) {
        guard coverSync || force, light.isPaired, light.isOn || force else { return }
        let color = nowPlaying.artwork != nil ? NSColor(nowPlaying.accent) : NSColor(srgbRed: 1, green: 0.62, blue: 0.3, alpha: 1)
        light.setColor(color, switchOn: force)
    }

    // MARK: - Claude light

    private var claudeLightReady: Bool { claudeLight && light.isPaired && light.reachable }

    private func claudeWaiting(_ waiting: Bool) {
        if waiting {
            guard claudeLightReady, pulseTimer == nil else { return }
            if beforeEffect == nil { beforeEffect = light.snapshot() }
            flashWork?.cancel()
            light.setColor(Self.claudeOrange)
            // Slow breathing: up and down every 1.4 s.
            let timer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulseHigh.toggle()
                self.light.setBrightness(self.pulseHigh ? 0.85 : 0.2)
            }
            pulseTimer = timer
        } else {
            stopPulse()
            restoreAfterEffect(delay: 0.2)
        }
    }

    private func claudeDone() {
        guard claudeLightReady else { return }
        stopPulse()
        if beforeEffect == nil { beforeEffect = light.snapshot() }
        light.setColor(NSColor(srgbRed: 0.2, green: 0.85, blue: 0.4, alpha: 1))
        light.setBrightness(0.9)
        restoreAfterEffect(delay: 1.6)
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func restoreAfterEffect(delay: Double) {
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pulseTimer == nil, let before = self.beforeEffect else { return }
            self.beforeEffect = nil
            self.light.restore(before)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func locked() {
        guard offOnLock, light.isPaired, light.isOn else { return }
        offForLock = true
        light.setOn(false)
    }

    private func unlocked() {
        guard offForLock else { return }
        offForLock = false
        light.setOn(true)
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(LightPage(module: self, light: light, moods: moods)) }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}

// MARK: - Page

/// A tall brightness tile on the left, filled from below in the light's
/// colour; on the right the light with its scene and a switch, and the
/// scenes as a list in two columns – the active one marked.
private struct LightPage: View {
    @ObservedObject var module: LightModule
    @ObservedObject var light: HueBluetoothLight
    @ObservedObject var moods: LightMoods
    @State private var pickingColor = false

    var body: some View {
        Group {
            if !light.isPaired {
                SetupView(light: light)
            } else {
                HStack(spacing: 16) {
                    BrightnessTile(light: light)
                        .disabled(!light.reachable)
                        .opacity(light.reachable ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 8) {
                        LightHeader(module: module, light: light, moods: moods)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                        Group {
                            if pickingColor {
                                ColorPane(module: module, light: light) {
                                    withAnimation(.easeInOut(duration: 0.2)) { pickingColor = false }
                                }
                            } else {
                                SceneList(module: module, moods: moods) {
                                    withAnimation(.easeInOut(duration: 0.2)) { pickingColor = true }
                                }
                            }
                        }
                        .disabled(!light.reachable)
                        .opacity(light.reachable ? 1 : 0.35)
                    }
                }
            }
        }
        .onAppear { light.refresh() }
    }
}

/// The light's name, its scene (or state) and a switch – or "Connect"
/// while it can't be reached.
private struct LightHeader: View {
    @ObservedObject var module: LightModule
    @ObservedObject var light: HueBluetoothLight
    @ObservedObject var moods: LightMoods

    private var connecting: Bool { light.phase == .connecting && !light.reachable }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(light.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if connecting {
                ProgressView().controlSize(.small)
            } else if light.reachable {
                Toggle("", isOn: Binding(get: { light.isOn }, set: { light.setOn($0) }))
                    .toggleStyle(.switch)
                    .tint(.green)
                    .labelsHidden()
            } else {
                Button { light.refresh() } label: {
                    Text(L("Verbinden", "Connect"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    private var status: String {
        if connecting { return L("Verbinde …", "Connecting …") }
        guard light.reachable else {
            switch light.phase {
            case .bluetoothOff: return L("Bluetooth aus", "Bluetooth off")
            case .unauthorized: return L("Kein Zugriff auf Bluetooth", "No Bluetooth access")
            default: return L("Nicht verbunden", "Not connected")
            }
        }
        guard light.isOn else { return L("Aus", "Off") }
        if module.activeMoodID == "free" { return L("Eigene Farbe", "Own colour") }
        if let scene = moods.all.first(where: { $0.id.uuidString == module.activeMoodID }) {
            return L("Szene: \(scene.name)", "Scene: \(scene.name)")
        }
        return L("An", "On")
    }
}

/// Tall tile like Control Center's: the brightness in per cent on top, the
/// bulb at the bottom, filled from below in the light's colour with a
/// bright edge and a soft glow above. Dragging moves the level from where
/// it is (no jump to the pointer); a plain click switches the light on or
/// off; all the way down switches it off.
private struct BrightnessTile: View {
    @ObservedObject var light: HueBluetoothLight
    /// The level while dragging.
    @State private var dragValue: Double?
    /// The level when the drag began.
    @State private var startValue = 0.0
    @State private var lastSent = Date.distantPast

    private func apply(_ value: Double) {
        if value < 0.03 {
            if light.isOn { light.setOn(false) }
        } else {
            light.setBrightness(value)
        }
    }

    var body: some View {
        let value = dragValue ?? (light.isOn ? light.brightness : 0)
        let dragging = dragValue != nil
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        GeometryReader { proxy in
            let height = proxy.size.height
            let fill = height * value
            ZStack(alignment: .bottom) {
                shape.fill(Color.white.opacity(dragging ? 0.11 : 0.08))
                // The light's colour glowing above the fill.
                LinearGradient(colors: [light.color.opacity(0), light.color.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: min(height, fill + height * 0.5))
                    .opacity(value > 0.001 ? 1 : 0)
                // The fill: lighter towards its top, with a bright edge.
                light.color
                    .overlay(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: fill)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.45)).frame(height: 1.5)
                            .opacity(value > 0.02 && value < 0.98 ? 1 : 0)
                    }
                VStack {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int((value * 100).rounded()))")
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(value: value))
                        Text("%")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 14)
                    Spacer()
                    Image(systemName: light.isOn ? "lightbulb.fill" : "lightbulb.slash")
                        .font(.system(size: 18, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.bottom, 14)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .clipShape(shape)
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragValue == nil { startValue = light.isOn ? light.brightness : 0 }
                    // Only moved far enough is a drag; up = brighter.
                    guard abs(drag.translation.height) > 2 || dragValue != nil else { return }
                    let new = min(max(startValue - drag.translation.height / height, 0), 1)
                    dragValue = new
                    // A Bluetooth write each ~80 ms is plenty.
                    if Date().timeIntervalSince(lastSent) > 0.08 {
                        lastSent = Date()
                        apply(new)
                    }
                }
                .onEnded { drag in
                    if let value = dragValue {
                        apply(value)
                    } else if abs(drag.translation.height) <= 2 {
                        light.toggle()
                    }
                    dragValue = nil
                })
        }
        .frame(width: 104)
        .scaleEffect(dragging ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragging)
        // Changes from elsewhere (a scene, the switch) glide.
        .animation(dragging ? nil : .spring(response: 0.45, dampingFraction: 0.9), value: value)
        .help(L("Ziehen für die Helligkeit, klicken zum Ein- und Ausschalten",
                "Drag for brightness, click to switch on or off"))
    }
}

/// The scenes as rows in two columns: symbol, name, a check on the active
/// one; "Own colour" last. More than six scroll.
private struct SceneList: View {
    @ObservedObject var module: LightModule
    @ObservedObject var moods: LightMoods
    let pickColor: () -> Void

    private enum Entry: Identifiable {
        case mood(LightMood), free
        var id: String { if case .mood(let mood) = self { return mood.id.uuidString }; return "free" }
    }

    var body: some View {
        let entries = moods.all.map(Entry.mood) + [.free]
        let rows = (entries.count + 1) / 2
        // Down the first column, then the second.
        let columns = [Array(entries.prefix(max(rows, 3))), Array(entries.dropFirst(max(rows, 3)))]
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(spacing: 2) {
                        ForEach(columns[column]) { entry in row(entry) }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .scrollDisabled(entries.count <= 6)
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .mood(let mood):
            let active = module.activeMoodID == mood.id.uuidString
            Button { module.apply(mood) } label: {
                content(active: active, name: mood.name) {
                    Image(systemName: mood.symbol.replacingOccurrences(of: ".fill", with: ""))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(active ? (mood.colors.last ?? .white) : .white.opacity(0.55))
                }
            }
            .buttonStyle(PressScaleStyle())
        case .free:
            Button(action: pickColor) {
                content(active: module.activeMoodID == "free", name: L("Eigene Farbe", "Own colour")) {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                      center: .center), lineWidth: 4)
                        .frame(width: 17, height: 17)
                }
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    private func content<Icon: View>(active: Bool, name: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon().frame(width: 20)
            Text(name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(active ? 0.1 : 0)))
        .contentShape(Rectangle())
    }
}

/// Free colour right in the island: drag across the field, the strip
/// follows; "Done" goes back to the moods.
private struct ColorPane: View {
    @ObservedObject var module: LightModule
    @ObservedObject var light: HueBluetoothLight
    let done: () -> Void
    @AppStorage("lightFreeHue") private var hue = 0.08
    @AppStorage("lightFreeSaturation") private var saturation = 0.8
    @State private var lastSent = Date.distantPast

    var body: some View {
        VStack(spacing: 8) {
            SpectrumPicker(hue: $hue, saturation: $saturation) { color in
                // Not every drag step needs a Bluetooth write.
                guard Date().timeIntervalSince(lastSent) > 0.1 else { return }
                lastSent = Date()
                module.applyFree(color)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: SpectrumPicker.color(hue: hue, saturation: saturation)))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                Text(L("Eigene Farbe", "Own colour"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button {
                    module.applyFree(SpectrumPicker.color(hue: hue, saturation: saturation))
                    done()
                } label: {
                    Text(L("Fertig", "Done"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}

/// First time: how to make the strip discoverable, and the search.
private struct SetupView: View {
    @ObservedObject var light: HueBluetoothLight

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                Circle().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                Image(systemName: "lightbulb.led.wide")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 70, height: 70)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Hue-Licht per Bluetooth verbinden", "Connect a Hue light over Bluetooth"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("In der Hue-App: Einstellungen → Sprachassistenten → Amazon Alexa → „Auffindbar machen“. Dann hier suchen.",
                       "In the Hue app: Settings → Voice assistants → Amazon Alexa → “Make discoverable”. Then search here."))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        light.search()
                    } label: {
                        HStack(spacing: 6) {
                            if light.phase == .searching { ProgressView().controlSize(.mini) }
                            Text(light.phase == .searching ? L("Suche …", "Searching …") : L("Suchen", "Search"))
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(light.phase == .searching)
                    if light.phase == .bluetoothOff {
                        Text(L("Bluetooth ist aus", "Bluetooth is off")).font(.system(size: 11)).foregroundStyle(.orange)
                    } else if light.phase == .unauthorized {
                        Text(L("Bluetooth in den Einstellungen erlauben", "Allow Bluetooth in System Settings"))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
