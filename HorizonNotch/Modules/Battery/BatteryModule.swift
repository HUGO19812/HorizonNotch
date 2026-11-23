import Combine
import SwiftUI

/// Short live activity when the charger is connected or removed, and a
/// warning when the battery runs low.
final class BatteryModule: NotchModule {
    enum Event: Equatable {
        case pluggedIn, unplugged, low(Int)
    }

    let id = "battery"
    var title: String { L("Akku & Laden", "Battery & Charging") }
    let symbol = "battery.75percent"
    let priority = ModulePriority.notification
    let compactWingWidth: CGFloat = 70

    @Published private(set) var event: Event?
    @Published private(set) var state: PowerSource.State

    private let power = PowerSource.shared
    private var subscription: AnyCancellable?
    private var hideWork: DispatchWorkItem?
    /// Thresholds already warned about since the last time on power.
    private var warned = Set<Int>()
    private static let lowThresholds = [20, 10, 5]

    var isActive: Bool { event != nil }
    /// When the charger is connected, a bar with the level and the time
    /// until full hangs below the wings.
    var isPeeking: Bool { event == .pluggedIn }
    var peekHeight: CGFloat { 52 }
    func peekView() -> AnyView { AnyView(ChargingProgress(module: self)) }

    init() {
        state = power.state
        subscription = power.$state.dropFirst().sink { [weak self] new in self?.update(to: new) }
    }

    private func update(to new: PowerSource.State) {
        let old = state
        state = new
        guard new.hasBattery else { return }
        if new.isPluggedIn && !old.isPluggedIn {
            warned.removeAll()
            present(.pluggedIn, for: 5.5)
        } else if !new.isPluggedIn && old.isPluggedIn {
            present(.unplugged, for: 2.6)
        } else if !new.isPluggedIn,
                  let threshold = Self.lowThresholds.first(where: { new.percent <= $0 && !warned.contains($0) && old.percent > $0 }) {
            warned.insert(threshold)
            present(.low(new.percent), for: 6)
        }
    }

    private func present(_ event: Event, for seconds: Double) {
        self.event = event
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.event = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    #if DEBUG
    func debugShow(_ event: Event) { present(event, for: 4) }
    #endif

    func compactLeading() -> AnyView { AnyView(BatteryLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(BatteryTrailing(module: self)) }
}

private struct BatteryLeading: View {
    @ObservedObject var module: BatteryModule
    @State private var glow = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            switch module.event {
            case .pluggedIn:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(theme.tint(.green))
                    .symbolEffect(.bounce, value: glow)
                Text(L("Lädt", "Charging"))
                    .foregroundStyle(.white.opacity(0.9))
            case .unplugged:
                Image(systemName: "powerplug.portrait")
                    .foregroundStyle(.white.opacity(0.75))
                Text(L("Akku", "Battery"))
                    .foregroundStyle(.white.opacity(0.75))
            case .low:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.tint(.red))
                    .symbolEffect(.pulse)
                Text(L("Niedrig", "Low"))
                    .foregroundStyle(theme.tint(.red))
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatCount(3, autoreverses: true)) { glow = true }
        }
    }
}

/// The charging card below the wings, clean like iOS: a large battery
/// outline that fills up from empty to the level with a green gradient
/// (yellow when low or in Low Power Mode), a sheen gliding across the fill,
/// the bolt on top, and beside it the percentage and the time until full.
private struct ChargingProgress: View {
    @ObservedObject var module: BatteryModule
    @Environment(\.islandTheme) private var theme
    @State private var shown = 0.0
    @State private var sheen = false
    @State private var boltIn = false

    var body: some View {
        let state = module.state
        HStack(spacing: 14) {
            battery(state)
                .frame(width: 66, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(state.percent) %")
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(state.percent)))
                // Re-read every few seconds: the estimate arrives a little later.
                TimelineView(.periodic(from: .now, by: 3)) { _ in
                    Text(remaining(state))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.9).delay(0.15)) {
                shown = min(max(Double(module.state.percent) / 100, 0), 1)
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.35)) { boltIn = true }
            withAnimation(.easeInOut(duration: 1.6).delay(0.9).repeatForever(autoreverses: false)) { sheen = true }
        }
        .onChange(of: state.percent) { _, value in
            withAnimation(.easeInOut(duration: 0.5)) { shown = min(max(Double(value) / 100, 0), 1) }
        }
    }

    private func fillColors(_ state: PowerSource.State) -> [Color] {
        if state.isLowPower || state.percent <= 20 {
            return [theme.tint(.yellow).opacity(0.75), theme.tint(.yellow)]
        }
        return [Color(red: 0.2, green: 0.78, blue: 0.35), Color(red: 0.4, green: 0.93, blue: 0.45)]
    }

    private func battery(_ state: PowerSource.State) -> some View {
        let body = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 2.5) {
            ZStack(alignment: .leading) {
                body.fill(Color.white.opacity(0.1))
                GeometryReader { proxy in
                    let inner = proxy.size.width - 6
                    let width = max(6, inner * shown)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(LinearGradient(colors: fillColors(state), startPoint: .leading, endPoint: .trailing))
                        // A soft band of light gliding across the fill.
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .white.opacity(0.45), location: 0.5),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 26)
                            .offset(x: sheen ? width + 4 : -30)
                            .blendMode(.plusLighter)
                    }
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: fillColors(state)[1].opacity(0.55), radius: 5)
                    .padding(3)
                }
                body.strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .scaleEffect(boltIn ? 1 : 0.2)
                    .opacity(boltIn ? 1 : 0)
                    .frame(maxWidth: .infinity)
            }
            Capsule()
                .fill(Color.white.opacity(0.4))
                .frame(width: 3, height: 10)
        }
    }

    /// Always "Full in …": macOS's estimate, else one from the charge rate,
    /// else a rough one from the level (about 1.3 min per percent).
    private func remaining(_ state: PowerSource.State) -> String {
        if state.percent >= 100 { return L("Voll", "Full") }
        let estimate = state.minutesRemaining ?? PowerSource.estimatedMinutesToFull()
        let minutes = max(1, estimate.flatMap { $0 > 0 ? $0 : nil } ?? Int((Double(100 - state.percent) * 1.3).rounded()))
        let time = minutes >= 60 ? L("\(minutes / 60) Std. \(minutes % 60) Min.", "\(minutes / 60) h \(minutes % 60) min")
                                 : L("\(minutes) Min.", "\(minutes) min")
        return L("Voll in \(time)", "Full in \(time)")
    }
}

private struct BatteryTrailing: View {
    @ObservedObject var module: BatteryModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let percent = module.state.percent
        HStack(spacing: 5) {
            Text("\(percent) %")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
            BatteryGlyph(fraction: Double(percent) / 100, color: color)
                .frame(width: 24, height: 11)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }

    private var color: Color {
        if module.state.isLowPower { return theme.tint(.yellow) }
        if module.state.isPluggedIn { return theme.tint(.green) }
        if module.state.percent <= 20 { return theme.tint(.red) }
        return .white
    }
}

/// Battery outline whose fill animates in from empty when it appears.
struct BatteryGlyph: View {
    let fraction: Double
    let color: Color
    @State private var shown = 0.0

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color)
                        .frame(width: max(2, (proxy.size.width - 3) * shown))
                        .padding(1.5)
                }
            }
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.45)).frame(width: 1.5, height: 4)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) { shown = min(max(fraction, 0), 1) }
        }
        .onChange(of: fraction) { _, value in
            withAnimation(.easeInOut(duration: 0.4)) { shown = min(max(value, 0), 1) }
        }
    }
}

// MARK: - Header indicator

/// Battery in the top right of the open island (like boringNotch): glyph,
/// optional percentage, bolt while charging; click for details.
struct HeaderBattery: View {
    @ObservedObject private var power = PowerSource.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showDetails = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let state = power.state
        if state.hasBattery, settings.batteryInHeader {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 3) {
                    // iOS 26/27 style: the level as a number inside the battery.
                    PhoneBattery(percent: state.percent, showNumber: settings.batteryShowPercent,
                                 fill: color(state))
                    if state.isCharging || state.isPluggedIn {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails, arrowEdge: .bottom) { BatteryDetails(state: state) }
        }
    }

    private func color(_ state: PowerSource.State) -> Color {
        if state.isLowPower { return theme.tint(.yellow) }
        if state.isPluggedIn { return theme.tint(.green) }
        if state.percent <= 20 { return theme.tint(.red) }
        return .white
    }
}

/// The battery as on iPhone since iOS 26: a rounded body, filled to the
/// level, the percentage cut out of it in bold, a small cap on the right.
struct PhoneBattery: View {
    let percent: Int
    var showNumber = true
    var fill: Color = .white

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4.3, style: .continuous)
        HStack(spacing: 1.2) {
            ZStack(alignment: .leading) {
                shape.fill(Color.white.opacity(0.32))
                GeometryReader { proxy in
                    Rectangle()
                        .fill(fill)
                        .frame(width: proxy.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
                if showNumber {
                    Text("\(percent)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        // Cut out of the battery, like the system's.
                        .blendMode(.destinationOut)
                }
            }
            .clipShape(shape)
            .compositingGroup()
            .frame(width: 26, height: 12.5)
            Capsule()
                .fill(Color.white.opacity(0.32))
                .frame(width: 1.6, height: 4.5)
        }
    }
}

private struct BatteryDetails: View {
    let state: PowerSource.State

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Akku \(state.percent) %", "Battery \(state.percent) %"))
                .font(.headline)
            Text(status).foregroundStyle(.secondary)
            if let minutes = state.minutesRemaining {
                Text(state.isCharging ? L("Voll in \(duration(minutes))", "Full in \(duration(minutes))")
                                      : L("Reicht noch \(duration(minutes))", "\(duration(minutes)) remaining"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(minWidth: 180, alignment: .leading)
    }

    private var status: String {
        if state.isCharging { return L("Lädt am Netzteil", "Charging") }
        if state.isPluggedIn { return L("Am Netzteil, lädt nicht", "On power, not charging") }
        return L("Akkubetrieb", "On battery")
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%d:%02d h", minutes / 60, minutes % 60) : "\(minutes) min"
    }
}
