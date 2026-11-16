import Combine
import SwiftUI

/// A Bluetooth device that connected or disconnected, with its battery.
struct DeviceCard: Equatable {
    var name: String
    var symbol: String
    var connected: Bool
    /// Percentages, nil when the device does not report them.
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Devices with one battery (headphones, keyboards …).
    var single: Int?
}

/// Like Pro Notch: when headphones connect, the island opens downwards into
/// a card – the device large on the left with a soft glow, its name and
/// "Connected", and a battery ring for each bud and the case.
final class DeviceCardModule: NotchModule {
    let id = "devices"
    var title: String { L("Geräte verbinden", "Device connections") }
    let symbol = "airpodspro"
    let priority = ModulePriority.notification + 1
    let compactWingWidth: CGFloat = 110

    @Published private(set) var card: DeviceCard?
    private var hideWork: DispatchWorkItem?

    var isActive: Bool { card != nil }
    var isPeeking: Bool { card != nil }
    var peekHeight: CGFloat { card?.connected == true ? 112 : 70 }

    /// Shows the card, or updates it in place (battery arriving later).
    func show(_ card: DeviceCard) {
        guard AppSettings.shared.isEnabled("connectivity") else { return }
        let same = self.card?.name == card.name && self.card?.connected == card.connected
        self.card = card
        if same, hideWork != nil { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.card = nil
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (card.connected ? 4.5 : 2.5), execute: work)
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func peekView() -> AnyView { AnyView(DeviceCardView(module: self)) }
    func transientView() -> AnyView { AnyView(DeviceCardView(module: self).frame(width: 360, height: peekHeight)) }
}

private struct DeviceCardView: View {
    @ObservedObject var module: DeviceCardModule

    var body: some View {
        if let card = module.card {
            HStack(spacing: 22) {
                Image(systemName: card.symbol)
                    .font(.system(size: card.connected ? 62 : 38, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(width: card.connected ? 104 : 60)
                    .background {
                        // Soft violet glow behind the device, like Pro Notch.
                        Circle()
                            .fill(Color(red: 0.55, green: 0.4, blue: 1).opacity(card.connected ? 0.35 : 0.15))
                            .blur(radius: 22)
                            .frame(width: 90, height: 90)
                    }
                    .opacity(card.connected ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(card.connected ? L("Verbunden", "Connected") : L("Getrennt", "Disconnected"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    if card.connected {
                        HStack(spacing: 12) {
                            if let left = card.left { BatteryRing(label: "L", percent: left) }
                            if let right = card.right { BatteryRing(label: "R", percent: right) }
                            if let box = card.caseLevel { BatteryRing(symbol: "rectangle.portrait.fill", percent: box) }
                            if card.left == nil, card.right == nil, let single = card.single {
                                BatteryRing(symbol: "battery.100", percent: single)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: card)
        }
    }
}

/// A ring that fills with the battery level, a letter or symbol inside and
/// the percentage below.
private struct BatteryRing: View {
    var label: String?
    var symbol: String?
    let percent: Int

    init(label: String, percent: Int) {
        self.label = label
        self.percent = percent
    }

    init(symbol: String, percent: Int) {
        self.symbol = symbol
        self.percent = percent
    }

    private var color: Color {
        percent <= 20 ? .red : (percent <= 40 ? .orange : Color(red: 0.45, green: 0.8, blue: 0.45))
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let label {
                    Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            Text("\(percent)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}
