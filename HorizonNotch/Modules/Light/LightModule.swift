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

/// The user's own moods (Settings → Light), stored as JSON.
final class LightMoods: ObservableObject {
    static let shared = LightMoods()
    private static let key = "lightMoods"

    @Published var custom: [LightMood] {
        didSet { if let data = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }

    var all: [LightMood] { LightMood.presets + custom }

    private init() {
        custom = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([LightMood].self, from: $0) } ?? []
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

    var headerInfo: HeaderInfo? {
        guard light.isPaired, light.hasState else { return nil }
        return .text(light.isOn ? "\(Int((light.brightness * 100).rounded())) %" : L("Aus", "Off"))
    }

    init(nowPlaying: NowPlayingService) {
        self.nowPlaying = nowPlaying
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
                    MoodGrid(module: module, moods: moods)
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
                    if state == .on {
                        Circle().fill(light.color.opacity(0.4)).blur(radius: 14).frame(width: 82, height: 82)
                    }
                    Circle().fill(fill(state))
                    if state == .disconnected || state == .connecting {
                        Circle().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                    if state == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state == .disconnected ? "antenna.radiowaves.left.and.right.slash" : "power")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(state == .on ? Color.black.opacity(0.72) : .white.opacity(state == .off ? 0.85 : 0.4))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 70, height: 70)
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

    private func fill(_ state: State) -> AnyShapeStyle {
        switch state {
        case .on:
            return AnyShapeStyle(LinearGradient(colors: [light.color, light.color.opacity(0.8)],
                                                startPoint: .top, endPoint: .bottom))
        case .off: return AnyShapeStyle(Color.white.opacity(0.14))
        default: return AnyShapeStyle(Color.white.opacity(0.06))
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

/// Tall brightness tile like Control Center: drag up and down.
private struct BrightnessTile: View {
    @ObservedObject var light: HueBluetoothLight
    @State private var dragValue: Double?
    @State private var lastSent = Date.distantPast

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
                    let new = min(max(1 - drag.location.y / proxy.size.height, 0.01), 1)
                    dragValue = new
                    // A Bluetooth write each ~80 ms is plenty.
                    if Date().timeIntervalSince(lastSent) > 0.08 {
                        lastSent = Date()
                        light.setBrightness(new)
                    }
                }
                .onEnded { _ in
                    if let value = dragValue { light.setBrightness(value) }
                    dragValue = nil
                })
        }
        .frame(width: 50)
        .help(L("Helligkeit", "Brightness"))
    }
}

private struct MoodGrid: View {
    @ObservedObject var module: LightModule
    @ObservedObject var moods: LightMoods

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(moods.all) { mood in
                    tile(mood)
                }
                FreeColorTile(active: module.activeMoodID == "free") { module.applyFree($0) }
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: SettingsTab.light.rawValue)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text(L("Neu", "New")).font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .help(L("Eigene Stimmung in den Einstellungen anlegen", "Create your own mood in Settings"))
            }
        }
    }

    private func tile(_ mood: LightMood) -> some View {
        let active = module.activeMoodID == mood.id.uuidString
        let dark = { if case .white = mood.kind { return true }; return false }()
        return Button { module.apply(mood) } label: {
            HStack(spacing: 6) {
                Image(systemName: mood.symbol).font(.system(size: 11, weight: .bold))
                Text(mood.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(dark ? Color.black.opacity(0.7) : .white)
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: mood.colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.white : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// "Own": opens the system colour panel; every colour picked there goes to
/// the light.
private struct FreeColorTile: View {
    let active: Bool
    let pick: (NSColor) -> Void

    var body: some View {
        Button { ColorPanelBridge.shared.show(pick) } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 16, height: 16)
                Text(L("Eigene", "Own")).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? Color.white : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Target for NSColorPanel, which reports changes through target/action.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var handler: ((NSColor) -> Void)?
    private var lastSent = Date.distantPast

    func show(_ handler: @escaping (NSColor) -> Void) {
        self.handler = handler
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.level = .statusBar + 1
        panel.orderFrontRegardless()
    }

    @objc private func changed(_ panel: NSColorPanel) {
        // Not every drag step needs a Bluetooth write.
        guard Date().timeIntervalSince(lastSent) > 0.12 else { return }
        lastSent = Date()
        handler?(panel.color)
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
