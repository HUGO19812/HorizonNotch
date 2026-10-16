import Combine
import SwiftUI

/// Shows next to the notch while a camera or microphone is in use, with the
/// icons of the apps recording audio.
final class PrivacyModule: NotchModule {
    let id = "privacy"
    var title: String { L("Kamera & Mikrofon", "Camera & Microphone") }
    let symbol = "video.fill"
    let priority = ModulePriority.privacy
    let compactWingWidth: CGFloat = 48

    let monitor = PrivacyMonitor()
    private var subscription: AnyCancellable?

    init() {
        subscription = monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var isActive: Bool { monitor.cameraActive || monitor.microphoneActive }

    func compactLeading() -> AnyView { AnyView(PrivacyIndicators(monitor: monitor)) }
    func compactTrailing() -> AnyView { AnyView(PrivacyApps(monitor: monitor)) }
}

private struct PrivacyIndicators: View {
    @ObservedObject var monitor: PrivacyMonitor
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if monitor.cameraActive {
                Image(systemName: "video.fill")
                    .foregroundStyle(theme.tint(.green))
                    .transition(.scale.combined(with: .opacity))
            }
            if monitor.microphoneActive {
                Image(systemName: "mic.fill")
                    .foregroundStyle(theme.tint(.orange))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: monitor.cameraActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: monitor.microphoneActive)
    }
}

private struct PrivacyApps: View {
    @ObservedObject var monitor: PrivacyMonitor
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: -5) {
            ForEach(monitor.microphoneApps.prefix(2), id: \.processIdentifier) { app in
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .help(app.localizedName ?? "")
                }
            }
            if monitor.microphoneApps.isEmpty {
                Circle()
                    .fill(theme.tint(monitor.cameraActive ? .green : .orange))
                    .frame(width: 7, height: 7)
                    .shadow(color: theme.tint(monitor.cameraActive ? .green : .orange), radius: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}
