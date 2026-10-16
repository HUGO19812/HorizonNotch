import Combine
import SwiftUI

/// Volume, mute and brightness HUD in the island, replacing the system
/// overlay while the key tap is active.
final class HUDModule: NotchModule {
    enum Kind: Equatable {
        case volume, brightness, keyboard
    }

    let id = "hud"
    var title: String { L("Lautstärke, Helligkeit & Tastaturlicht", "Volume, Brightness & Keyboard Light") }
    let symbol = "speaker.wave.2.fill"
    let priority = ModulePriority.hud
    let compactWingWidth: CGFloat = 78

    @Published private(set) var kind: Kind = .volume
    @Published private(set) var level: Float = 0
    @Published private(set) var muted = false
    @Published private(set) var visible = false
    /// Bumped on every key press so the icon can bounce.
    @Published private(set) var pulse = 0

    private let tap = MediaKeyTap()
    private let output = AudioOutput.shared
    private var hideWork: DispatchWorkItem?
    private var lastKeyboardLevel: Float = 0
    private var subscriptions = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    /// In the side-bar style the island stays as it is.
    var isActive: Bool { visible && settings.hudStyle == .notch }
    private let sideHUD = SideHUDController()
    var tapIsRunning: Bool { tap.isRunning }

    init() {
        tap.onKey = { [weak self] key, fine in
            self?.handle(key, fine: fine) ?? false
        }
        settings.$replaceSystemHUD
            .sink { [weak self] enabled in
                DispatchQueue.main.async { self?.updateTap(enabled: enabled && (self?.settings.isEnabled("hud") ?? true)) }
            }
            .store(in: &subscriptions)
        settings.$disabledModules
            .sink { [weak self] disabled in
                DispatchQueue.main.async {
                    self?.updateTap(enabled: !disabled.contains("hud") && (self?.settings.replaceSystemHUD ?? false))
                }
            }
            .store(in: &subscriptions)
    }

    /// Starts the tap if allowed; call again after the Accessibility
    /// permission was granted.
    func updateTap(enabled: Bool) {
        if enabled { tap.start() } else { tap.stop() }
        objectWillChange.send()
    }

    // MARK: - Keys

    private func handle(_ key: MediaKeyTap.Key, fine: Bool) -> Bool {
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .volumeUp, .volumeDown:
            guard output.canSetVolume else { return false }
            var value = output.volume
            value += key == .volumeUp ? step : -step
            value = (value / step).rounded() * step
            output.volume = value
            if output.isMuted && key == .volumeUp { output.isMuted = false }
            show(.volume, level: output.volume, muted: output.isMuted || output.volume <= 0)
        case .mute:
            output.isMuted.toggle()
            show(.volume, level: output.volume, muted: output.isMuted)
        case .brightnessUp, .brightnessDown:
            guard DisplayBrightness.isAvailable, let current = DisplayBrightness.brightness else { return false }
            var value = current + (key == .brightnessUp ? step : -step)
            value = min(max((value / step).rounded() * step, 0), 1)
            DisplayBrightness.setBrightness(value)
            show(.brightness, level: value, muted: false)
        case .keyboardUp, .keyboardDown, .keyboardToggle:
            guard KeyboardBacklight.isAvailable, let current = KeyboardBacklight.brightness else { return false }
            var value: Float
            if key == .keyboardToggle {
                value = current > 0 ? 0 : (lastKeyboardLevel > 0 ? lastKeyboardLevel : 0.5)
            } else {
                value = current + (key == .keyboardUp ? step : -step)
                value = min(max((value / step).rounded() * step, 0), 1)
            }
            if current > 0 { lastKeyboardLevel = current }
            KeyboardBacklight.setBrightness(value)
            show(.keyboard, level: value, muted: false)
        }
        return true
    }

    private func show(_ kind: Kind, level: Float, muted: Bool) {
        if settings.hudStyle == .sideBar {
            sideHUD.show(kind: kind, level: level, muted: muted)
            return
        }
        self.kind = kind
        self.level = level
        self.muted = muted
        pulse &+= 1
        if !visible { visible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.visible = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    #if DEBUG
    func debugShow() { show(.volume, level: output.volume, muted: output.isMuted) }
    #endif

    // MARK: - Views

    func compactLeading() -> AnyView { AnyView(HUDIcon(module: self)) }
    func compactTrailing() -> AnyView { AnyView(HUDLevelBar(module: self)) }
}

private struct HUDIcon: View {
    @ObservedObject var module: HUDModule

    private var symbol: String {
        switch module.kind {
        case .brightness:
            return module.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard:
            return module.level <= 0 ? "light.min" : "light.max"
        case .volume:
            if module.muted { return "speaker.slash.fill" }
            switch module.level {
            case ..<0.01: return "speaker.fill"
            case ..<0.34: return "speaker.wave.1.fill"
            case ..<0.67: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
            }
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: module.pulse)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
    }
}

private struct HUDLevelBar: View {
    @ObservedObject var module: HUDModule
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.islandTheme) private var theme

    private var barColor: Color {
        switch module.kind {
        case .brightness: return theme.tint(Color.yellow.opacity(0.95))
        case .keyboard: return theme.tint(Color(red: 0.55, green: 0.8, blue: 1))
        case .volume: return .white
        }
    }

    var body: some View {
        let level = CGFloat(module.muted ? 0 : module.level)
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(barColor)
                        .frame(width: max(0, proxy.size.width * level))
                }
            }
            .frame(width: settings.hudShowPercent ? 46 : 62, height: 5)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
            if settings.hudShowPercent {
                Text("\(Int((level * 100).rounded()))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, alignment: .trailing)
                    .contentTransition(.numericText())
            }
        }
        .padding(.trailing, 8)
    }
}
