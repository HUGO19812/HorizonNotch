import Combine
import SwiftUI

/// Bluetooth at a glance, like the Light tab's list: every paired device
/// with its symbol, battery and state; a click connects or disconnects it.
final class BluetoothModule: NotchModule {
    let id = "bluetooth"
    var title: String { "Bluetooth" }
    let symbol = "dot.radiowaves.left.and.right"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    let hub = BluetoothHub.shared
    private var subscriptions = Set<AnyCancellable>()

    var headerInfo: HeaderInfo? {
        let count = hub.devices.filter(\.isConnected).count
        return count > 0 ? .text("\(count)") : nil
    }

    init() {
        hub.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(BluetoothPage(hub: hub)) }
}

private struct BluetoothPage: View {
    @ObservedObject var hub: BluetoothHub
    @ObservedObject private var output = AudioOutput.shared
    /// Batteries change slowly; a look every half minute is enough.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            if hub.devices.isEmpty {
                Text(L("Keine Geräte gekoppelt – in den Systemeinstellungen → Bluetooth koppeln.",
                       "No devices paired – pair them in System Settings → Bluetooth."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                list
            }
        }
        // Bluetooth is asked only once the tab is opened.
        .onAppear { hub.start() }
        .onReceive(tick) { _ in hub.refresh() }
    }

    private var header: some View {
        let connected = hub.devices.filter(\.isConnected).count
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(connected > 0 ? Color.blue : Color.white.opacity(0.12))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bluetooth")
                    .font(.system(size: 16, weight: .semibold))
                Text(connected == 0 ? L("Nichts verbunden", "Nothing connected")
                     : L("\(connected) verbunden", "\(connected) connected"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    private var list: some View {
        let devices = hub.devices
        let firstColumn = max((devices.count + 1) / 2, 3)
        let columns = [Array(devices.prefix(firstColumn)), Array(devices.dropFirst(firstColumn))]
        return ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(spacing: 2) {
                        ForEach(columns[column]) { device in row(device) }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .scrollDisabled(devices.count <= 6)
    }

    private func row(_ device: BluetoothHub.Device) -> some View {
        let connecting = hub.connecting.contains(device.id)
        let failed = hub.unreachable == device.id
        return Button { hub.toggle(device) } label: {
            HStack(spacing: 9) {
                Image(systemName: device.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(device.isConnected ? Color.white : .white.opacity(0.45))
                    .frame(width: 22)
                Text(device.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(device.isConnected ? Color.white : .white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hub.isOutput(device) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .help(L("Ton läuft hier", "Sound plays here"))
                }
                if let battery = device.battery {
                    Text("\(battery) %")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(battery <= 20 ? Color.red : .white.opacity(0.55))
                }
                Group {
                    if connecting {
                        ProgressView().controlSize(.mini)
                    } else if failed {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    } else if device.isConnected {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                    }
                }
                .font(.system(size: 12))
                .frame(width: 14)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(device.isConnected ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(connecting)
        .help(failed ? L("Nicht erreichbar – ist es an und in der Nähe?", "Not reachable – is it on and nearby?")
              : (device.isConnected ? L("Klicken zum Trennen", "Click to disconnect")
                 : L("Klicken zum Verbinden", "Click to connect")))
    }
}
