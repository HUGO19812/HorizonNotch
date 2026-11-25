import Combine
import SwiftUI

/// The Bluetooth speakers (KRK Kreate 3) on their own page, in the style of
/// the Light tab: connect with a switch, a wide volume slider, and the
/// outputs as tiles to send the sound to.
final class SpeakerModule: NotchModule {
    let id = "speaker"
    var title: String { L("Boxen", "Speakers") }
    let symbol = "hifispeaker.2.fill"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    let speaker = BluetoothSpeaker.shared
    private var subscriptions = Set<AnyCancellable>()

    var headerInfo: HeaderInfo? {
        speaker.isConnected ? .text(L("Verbunden", "Connected")) : nil
    }

    init() {
        speaker.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(SpeakerPage(speaker: speaker)) }
}

private struct SpeakerPage: View {
    @ObservedObject var speaker: BluetoothSpeaker

    var body: some View {
        Group {
            if speaker.name == nil {
                SpeakerSetup(speaker: speaker)
            } else {
                VStack(spacing: 10) {
                    SpeakerHeader(speaker: speaker)
                    VolumeSlider()
                    OutputRow(speaker: speaker)
                }
            }
        }
        // Bluetooth is asked only once the page is opened.
        .onAppear { speaker.start() }
    }
}

/// The speakers' icon (bright while connected), name, state and a switch
/// that connects or disconnects them.
private struct SpeakerHeader: View {
    @ObservedObject var speaker: BluetoothSpeaker
    @ObservedObject private var output = AudioOutput.shared

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(speaker.isConnected ? Color.white : Color.white.opacity(0.12))
                if speaker.isConnecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(speaker.isConnected ? Color.black : .white.opacity(0.6))
                }
            }
            .frame(width: 30, height: 30)
            .shadow(color: speaker.isConnected ? .white.opacity(0.35) : .clear, radius: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(speaker.name ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(speaker.problem != nil && !speaker.isConnected ? Color.orange : .white.opacity(0.55))
                    .lineLimit(1)
            }
            .contextMenu {
                if speaker.candidates.count > 1 {
                    Button(L("Andere Boxen wählen …", "Choose other speakers …")) { speaker.forget() }
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { speaker.isConnected || speaker.isConnecting },
                                     set: { $0 ? speaker.connect() : speaker.disconnect() }))
                .toggleStyle(.switch)
                .tint(.green)
                .labelsHidden()
                .disabled(speaker.isConnecting)
        }
        .animation(.easeInOut(duration: 0.25), value: speaker.isConnected)
    }

    private var status: String {
        if speaker.isConnecting { return L("Verbinde …", "Connecting …") }
        if !speaker.isConnected { return speaker.problem ?? L("Nicht verbunden", "Not connected") }
        return speaker.isOutput ? L("Verbunden · spielt hier", "Connected · playing here")
            : L("Verbunden · Ton läuft über \(output.deviceName)", "Connected · sound on \(output.deviceName)")
    }
}

/// Volume of the current output, wide like the light's brightness; the
/// speaker symbol on the left mutes.
private struct VolumeSlider: View {
    @ObservedObject private var output = AudioOutput.shared
    @State private var level = Double(AudioOutput.shared.volume)
    @State private var muted = AudioOutput.shared.isMuted
    @State private var dragging = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let shown = muted ? 0 : level
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(Color.white.opacity(0.92))
                    .frame(width: max(proxy.size.height, proxy.size.width * shown))
                    .opacity(shown > 0.001 ? 1 : 0)
                HStack {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(shown > 0.06 ? Color.black.opacity(0.5) : .white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            muted.toggle()
                            AudioOutput.shared.isMuted = muted
                        }
                    Spacer()
                    Text("\(Int((shown * 100).rounded())) %")
                        .monospacedDigit()
                        .foregroundStyle(shown > 0.9 ? Color.black.opacity(0.5) : .white.opacity(0.6))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    level = Double(min(max(drag.location.x / proxy.size.width, 0), 1))
                    if muted { muted = false; AudioOutput.shared.isMuted = false }
                    AudioOutput.shared.volume = Float(level)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 28)
        .disabled(!output.canSetVolume)
        .opacity(output.canSetVolume ? 1 : 0.4)
        .help(output.canSetVolume ? L("Lautstärke von \(output.deviceName)", "Volume of \(output.deviceName)")
              : L("Diese Ausgabe hat keine eigene Lautstärke", "This output has no volume of its own"))
        // Volume keys or another app may change it too.
        .onReceive(tick) { _ in
            guard !dragging else { return }
            level = Double(AudioOutput.shared.volume)
            muted = AudioOutput.shared.isMuted
        }
        .onChange(of: output.deviceName) { _, _ in
            level = Double(AudioOutput.shared.volume)
            muted = AudioOutput.shared.isMuted
        }
    }
}

/// The outputs as tiles: the speakers first, then up to three others
/// (Mac speakers, headphones …); the playing one is white.
private struct OutputRow: View {
    @ObservedObject var speaker: BluetoothSpeaker
    @ObservedObject private var output = AudioOutput.shared

    var body: some View {
        let others = output.devices.filter { $0.name != speaker.name }.prefix(3)
        HStack(spacing: 8) {
            tile(name: speaker.name ?? "KRK", symbol: "hifispeaker.2.fill", active: speaker.isOutput,
                 enabled: speaker.isConnected) {
                speaker.selectAsOutput()
            }
            ForEach(Array(others)) { device in
                tile(name: device.name, symbol: device.symbol, active: device.id == output.currentID, enabled: true) {
                    output.select(device)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tile(name: String, symbol: String, active: Bool, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(active ? Color.black.opacity(0.08) : Color.white.opacity(0.14))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(active ? Color.black : .white)
                }
                .frame(width: 36, height: 36)
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(active ? Color.black : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(active ? Color.white : Color.white.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .animation(.easeInOut(duration: 0.2), value: active)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(name)
    }
}

/// No KRK among the paired devices: the paired audio devices to pick from,
/// or how to pair.
private struct SpeakerSetup: View {
    @ObservedObject var speaker: BluetoothSpeaker

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                Circle().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                Image(systemName: "hifispeaker.2")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 70, height: 70)
            VStack(alignment: .leading, spacing: 8) {
                Text(speaker.candidates.isEmpty ? L("Keine Bluetooth-Boxen gekoppelt", "No Bluetooth speakers paired")
                     : L("Welche Boxen?", "Which speakers?"))
                    .font(.system(size: 14, weight: .semibold))
                if speaker.candidates.isEmpty {
                    Text(L("Die Boxen einmal in den Systemeinstellungen → Bluetooth koppeln, dann erscheinen sie hier.",
                           "Pair the speakers once in System Settings → Bluetooth; then they show up here."))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        ForEach(speaker.candidates.prefix(4)) { candidate in
                            Button { speaker.choose(candidate) } label: {
                                Text(candidate.name)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .frame(height: 24)
                                    .background(Capsule().fill(Color.white))
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
