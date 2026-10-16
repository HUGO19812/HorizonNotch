import AppKit
import SwiftUI

/// Alternative HUD style: a slim vertical bar at the left edge of the
/// screen, vertically centred. Slides in on a key press, out after a moment.
final class SideHUDController {
    final class State: ObservableObject {
        @Published var kind: HUDModule.Kind = .volume
        @Published var level: Float = 0
        @Published var muted = false
        @Published var shown = false
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let size = CGSize(width: 46, height: 230)

    func show(kind: HUDModule.Kind, level: Float, muted: Bool) {
        let panel = panel ?? makePanel()
        if let screen = NSScreen.islandScreen(preferred: AppSettings.shared.displayID) {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.minX + 10, y: frame.midY - Self.size.height / 2,
                                  width: Self.size.width, height: Self.size.height), display: false)
        }
        state.kind = kind
        state.level = level
        state.muted = muted
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { state.shown = true }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.state.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.state.shown { self.panel?.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SideHUDView(state: state))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private struct SideHUDView: View {
    @ObservedObject var state: SideHUDController.State
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let level = CGFloat(state.muted ? 0 : state.level)
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(fill)
                        .frame(height: max(proxy.size.width, proxy.size.height * level))
                        .opacity(level > 0 ? 1 : 0)
                }
            }
            .frame(width: 8)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 16)
        }
        .padding(.vertical, 16)
        .frame(width: 40)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: state.shown ? 0 : -60)
        .opacity(state.shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var fill: Color {
        switch state.kind {
        case .brightness: return settings.tint(.yellow)
        case .keyboard: return settings.tint(Color(red: 0.55, green: 0.8, blue: 1))
        case .volume: return .white
        }
    }

    private var symbol: String {
        switch state.kind {
        case .brightness: return state.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard: return state.level <= 0 ? "light.min" : "light.max"
        case .volume:
            if state.muted { return "speaker.slash.fill" }
            return state.level < 0.34 ? "speaker.wave.1.fill" : (state.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }
}
