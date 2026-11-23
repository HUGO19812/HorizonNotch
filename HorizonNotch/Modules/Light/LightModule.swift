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

/// The Hue light strip on its own page, like Control Center: the power
/// button (grey and dashed while not connected, dark when off, glowing when
/// on), a tall brightness tile, and the moods in a grid with a free colour
/// and "New" at the end.
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
                HStack(spacing: 14) {
                    PowerButton(light: light)
                    BrightnessTile(light: light)
                        .disabled(!connected)
                        .opacity(connected ? 1 : 0.35)
                    Group {
                        if pickingColor {
                            ColorPane(module: module, light: light) {
                                withAnimation(.easeInOut(duration: 0.2)) { pickingColor = false }
                            }
                        } else {
                            MoodGrid(module: module, moods: moods) {
                                withAnimation(.easeInOut(duration: 0.2)) { pickingColor = true }
                            }
                        }
                    }
                    .disabled(!connected)
                    .opacity(connected ? 1 : 0.35)
                }
            }
        }
        .onAppear { light.refresh() }
    }

    private var connected: Bool { light.reachable }
}

/// Grey and dashed while not connected, dark when off, glowing when on.
private struct PowerButton: View {
    @ObservedObject var light: HueBluetoothLight

    private enum State { case disconnected, connecting, off, on }

    private var state: State {
        if light.phase == .connecting && !light.reachable { return .connecting }
        if !light.reachable { return .disconnected }
        return light.isOn ? .on : .off
    }

    var body: some View {
        let state = state
        VStack(spacing: 6) {
            Button {
                if state == .disconnected { light.refresh() } else { light.toggle() }
            } label: {
                ZStack {
                    if state == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol(state))
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(state == .on ? Color.white : .white.opacity(state == .off ? 0.85 : 0.4))
                            .shadow(color: state == .on ? .black.opacity(0.25) : .clear, radius: 2, y: 1)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 66, height: 66)
                .modifier(GlassDisc(tint: state == .on ? light.color : nil, dimmed: state == .disconnected || state == .connecting))
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .help(state == .disconnected ? L("Erneut verbinden", "Connect again") : light.name)
            Text(label(state))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(state == .disconnected || state == .connecting ? 0.4 : 0.7))
                .lineLimit(1)
        }
        .frame(width: 92)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private func symbol(_ state: State) -> String {
        switch state {
        case .on: return "lightbulb.led.wide.fill"
        case .off: return "lightbulb.led.wide"
        default: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func label(_ state: State) -> String {
        switch state {
        case .on: return L("An", "On")
        case .off: return L("Aus", "Off")
        case .connecting: return L("Verbinde …", "Connecting …")
        case .disconnected:
            switch light.phase {
            case .bluetoothOff: return L("Bluetooth aus", "Bluetooth off")
            case .unauthorized: return L("Kein Zugriff", "No access")
            default: return L("Nicht verbunden", "Not connected")
            }
        }
    }
}

/// The button's disc: Liquid Glass on macOS 26 and later, tinted with the
/// light's colour while it's on; a soft material circle before that.
private struct GlassDisc: ViewModifier {
    let tint: Color?
    let dimmed: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    // The light's colour glowing under the glass.
                    if let tint { Circle().fill(tint.opacity(0.55)).blur(radius: 12).scaleEffect(1.15) }
                }
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.75)).interactive() } ?? Glass.regular.interactive(),
                             in: Circle())
                .opacity(dimmed ? 0.55 : 1)
        } else {
            content
                .background(Circle().fill(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.ultraThinMaterial)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .opacity(dimmed ? 0.55 : 1)
        }
    }
}

/// Tall brightness tile like Control Center: drag up and down; all the way
/// down switches the light off.
private struct BrightnessTile: View {
    @ObservedObject var light: HueBluetoothLight
    @State private var dragValue: Double?
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
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.1))
                Rectangle().fill(Color.white.opacity(0.9))
                    .frame(height: proxy.size.height * max(value, 0.001))
                Image(systemName: value > 0.5 ? "sun.max.fill" : "sun.min.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(value > 0.12 ? Color.black.opacity(0.6) : .white.opacity(0.6))
                    .padding(.bottom, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let new = min(max(1 - drag.location.y / proxy.size.height, 0), 1)
                    dragValue = new
                    // A Bluetooth write each ~80 ms is plenty.
                    if Date().timeIntervalSince(lastSent) > 0.08 {
                        lastSent = Date()
                        apply(new)
                    }
                }
                .onEnded { _ in
                    if let value = dragValue { apply(value) }
                    dragValue = nil
                })
        }
        .frame(width: 50)
        .help(L("Helligkeit", "Brightness"))
    }
}

/// The scenes as panels. Up to 5 sit in one row of big panels (with names
/// up to 3), 6–8 in two rows where each row fills the width on its own, so
/// there's never a gap; more go on further pages (dots top right). The
/// active scene's name stands above. "Own" is the last panel.
private struct MoodGrid: View {
    @ObservedObject var module: LightModule
    @ObservedObject var moods: LightMoods
    let pickColor: () -> Void
    @State private var page = 0

    private enum Entry: Identifiable {
        case mood(LightMood), free
        var id: String { if case .mood(let mood) = self { return mood.id.uuidString }; return "free" }
    }

    private static let perPage = 8

    var body: some View {
        let entries = moods.all.map(Entry.mood) + [.free]
        let pages = max(1, (entries.count + Self.perPage - 1) / Self.perPage)
        let current = min(page, pages - 1)
        let shown = Array(entries.dropFirst(current * Self.perPage).prefix(Self.perPage))
        let rows = shown.count <= 5 ? 1 : 2
        let perRow = (shown.count + rows - 1) / rows
        let withNames = shown.count <= 3
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(activeName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                Spacer()
                if pages > 1 {
                    HStack(spacing: 5) {
                        ForEach(0..<pages, id: \.self) { index in
                            Circle()
                                .fill(Color.white.opacity(index == current ? 0.85 : 0.25))
                                .frame(width: 6, height: 6)
                                .contentShape(Rectangle().inset(by: -4))
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { page = index } }
                        }
                    }
                }
            }
            VStack(spacing: 8) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(Array(shown.dropFirst(row * perRow).prefix(perRow))) { entry in
                            tile(entry, withName: withNames)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .id(current)
            .transition(.opacity)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
            guard pages > 1, abs(drag.translation.width) > abs(drag.translation.height) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                page = drag.translation.width < 0 ? min(current + 1, pages - 1) : max(current - 1, 0)
            }
        })
    }

    private var activeName: String {
        if module.activeMoodID == "free" { return L("Eigene Farbe", "Own colour") }
        return moods.all.first { $0.id.uuidString == module.activeMoodID }?.name ?? L("Szenen", "Scenes")
    }

    @ViewBuilder
    private func tile(_ entry: Entry, withName: Bool) -> some View {
        switch entry {
        case .mood(let mood):
            let active = module.activeMoodID == mood.id.uuidString
            let dark = { if case .white = mood.kind { return true }; return false }()
            Button { module.apply(mood) } label: {
                panel(fill: AnyShapeStyle(LinearGradient(colors: mood.colors, startPoint: .topLeading, endPoint: .bottomTrailing)),
                      active: active) {
                    Image(systemName: mood.symbol).font(.system(size: withName ? 12 : 13, weight: .bold))
                    if withName {
                        Text(mood.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                .foregroundStyle(dark ? Color.black.opacity(0.7) : .white)
            }
            .buttonStyle(PressScaleStyle())
            .help(mood.name)
        case .free:
            Button(action: pickColor) {
                panel(fill: AnyShapeStyle(Color.white.opacity(0.09)), active: module.activeMoodID == "free") {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 16, height: 16)
                    if withName { Text(L("Eigene", "Own")).font(.system(size: 11.5, weight: .semibold)) }
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(PressScaleStyle())
            .help(L("Eigene Farbe", "Own colour"))
        }
    }

    private func panel<Content: View>(fill: AnyShapeStyle, active: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.white : .clear, lineWidth: 2))
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
