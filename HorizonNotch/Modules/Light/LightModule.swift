import AppKit
import Combine
import SwiftUI

/// The Hue light strip on its own page: a big power button glowing in the
/// light's colour, a brightness bar, whites and colours to tap, and two
/// options – follow the cover's colour, switch off while the Mac is locked.
final class LightModule: NotchModule {
    let id = "light"
    var title: String { L("Licht", "Light") }
    let symbol = "lightbulb.led.wide.fill"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    let light = HueBluetoothLight.shared
    private let nowPlaying: NowPlayingService
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// Switched off because the Mac locked; switched on again on unlock.
    private var offForLock = false

    @AppStorage("lightCoverSync") var coverSync = false {
        didSet { if coverSync { followCover() } }
    }
    @AppStorage("lightOffOnLock") var offOnLock = false

    var headerInfo: HeaderInfo? {
        guard light.isPaired, light.hasState else { return nil }
        return .text(light.isOn ? "\(Int((light.brightness * 100).rounded())) %" : L("Aus", "Off"))
    }

    init(nowPlaying: NowPlayingService) {
        self.nowPlaying = nowPlaying
        light.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
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

    /// The cover's colour, when that option is on and the light is on.
    private func followCover() {
        guard coverSync, light.isPaired, light.isOn, nowPlaying.artwork != nil else { return }
        light.setColor(NSColor(nowPlaying.accent), switchOn: false)
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
    func expandedView() -> AnyView { AnyView(LightPage(module: self, light: light)) }
}

// MARK: - Page

private struct LightPage: View {
    @ObservedObject var module: LightModule
    @ObservedObject var light: HueBluetoothLight

    var body: some View {
        Group {
            if !light.isPaired || light.phase == .searching && !light.hasState {
                SetupView(light: light)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    PowerButton(light: light)
                        .frame(width: 128)
                    VStack(alignment: .leading, spacing: 10) {
                        BrightnessBar(light: light)
                        Swatches(light: light)
                        HStack(spacing: 8) {
                            OptionChip(title: L("Cover-Farbe", "Cover colour"), symbol: "music.note",
                                       on: module.coverSync) { module.coverSync.toggle() }
                                .help(L("Der Streifen nimmt die Farbe des laufenden Covers an",
                                        "The strip takes the colour of the playing cover"))
                            OptionChip(title: L("Beim Sperren aus", "Off when locked"), symbol: "lock.fill",
                                       on: module.offOnLock) { module.offOnLock.toggle() }
                            Spacer(minLength: 0)
                            Menu {
                                Button(L("Neu verbinden", "Reconnect")) { light.refresh() }
                                Button(L("Anderen Streifen suchen", "Find another strip")) { light.search() }
                                Divider()
                                Button(L("Vergessen", "Forget"), role: .destructive) { light.forget() }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 24, height: 22)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .onAppear { light.refresh() }
    }
}

/// Round button, glowing in the light's colour while it is on.
private struct PowerButton: View {
    @ObservedObject var light: HueBluetoothLight

    var body: some View {
        VStack(spacing: 7) {
            Button { light.toggle() } label: {
                ZStack {
                    Circle()
                        .fill(light.isOn ? light.color.opacity(0.9) : Color.white.opacity(0.08))
                        .shadow(color: light.isOn ? light.color.opacity(0.7) : .clear, radius: 16)
                    Image(systemName: light.isOn ? "lightbulb.led.wide.fill" : "lightbulb.led.wide")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(light.isOn ? Color.black.opacity(0.75) : .white.opacity(0.7))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 62, height: 62)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .animation(.easeInOut(duration: 0.25), value: light.isOn)
            VStack(spacing: 1) {
                Text(light.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var status: String {
        switch light.phase {
        case .connecting: return L("Verbinde …", "Connecting …")
        case .bluetoothOff: return L("Bluetooth ist aus", "Bluetooth is off")
        case .unauthorized: return L("Kein Bluetooth-Zugriff", "No Bluetooth access")
        default:
            guard light.hasState else { return L("Nicht erreichbar", "Out of reach") }
            return light.isOn ? L("An · \(Int((light.brightness * 100).rounded())) %", "On · \(Int((light.brightness * 100).rounded())) %")
                              : L("Aus", "Off")
        }
    }
}

/// Wide bar from dim to bright, filled in the light's colour.
private struct BrightnessBar: View {
    @ObservedObject var light: HueBluetoothLight
    @State private var dragValue: Double?
    @State private var lastSent = Date.distantPast

    var body: some View {
        let value = dragValue ?? (light.isOn ? light.brightness : 0)
        HStack(spacing: 9) {
            Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [light.color.opacity(0.55), light.color],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(22, proxy.size.width * value))
                        .opacity(light.isOn || dragValue != nil ? 1 : 0.25)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let new = min(max(drag.location.x / proxy.size.width, 0.01), 1)
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
            .frame(height: 22)
            Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Three whites and six colours, plus the system colour picker.
private struct Swatches: View {
    @ObservedObject var light: HueBluetoothLight
    @State private var custom = Color.purple

    private let whites: [Double] = [2200, 3000, 4000, 6500]
    private let colors: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.18, blue: 0.15, alpha: 1), NSColor(srgbRed: 1, green: 0.5, blue: 0.1, alpha: 1),
        NSColor(srgbRed: 1, green: 0.3, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.6, green: 0.3, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.45, blue: 1, alpha: 1), NSColor(srgbRed: 0.2, green: 0.85, blue: 0.4, alpha: 1),
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(whites, id: \.self) { kelvin in
                swatch(HueBluetoothLight.whiteColor(kelvin: kelvin)) { light.setWhite(kelvin: kelvin) }
                    .help("\(Int(kelvin)) K")
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16)
            ForEach(colors.indices, id: \.self) { index in
                swatch(Color(nsColor: colors[index])) { light.setColor(colors[index]) }
            }
            ColorPicker("", selection: $custom, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 22, height: 22)
                .onChange(of: custom) { _, value in light.setColor(NSColor(value)) }
                .help(L("Eigene Farbe", "Custom colour"))
        }
    }

    private func swatch(_ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct OptionChip: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(on ? Color.black : .white.opacity(0.75))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// First time: how to make the strip discoverable, and the search.
private struct SetupView: View {
    @ObservedObject var light: HueBluetoothLight

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "lightbulb.led.wide")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 70, height: 70)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08)))
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
