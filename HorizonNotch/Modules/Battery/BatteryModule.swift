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
            present(.pluggedIn, for: 3.2)
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
                    .scaleEffect(glow ? 1.15 : 0.85)
                    .shadow(color: theme.tint(.green).opacity(glow ? 0.9 : 0.2), radius: glow ? 6 : 1)
                Text(L("Lädt", "Charging"))
                    .foregroundStyle(theme.tint(.green))
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
                HStack(spacing: 4) {
                    if settings.batteryShowPercent {
                        Text("\(state.percent) %")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    BatteryGlyph(fraction: Double(state.percent) / 100, color: color(state))
                        .frame(width: 22, height: 10)
                        .overlay {
                            if state.isCharging || state.isPluggedIn {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black, radius: 1)
                                    .offset(x: -1)
                            }
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
        if state.isPluggedIn { return theme.tint(.green) }
        if state.percent <= 20 { return theme.tint(.red) }
        return .white
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
