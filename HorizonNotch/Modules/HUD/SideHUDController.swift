import AppKit
import SwiftUI

/// Alternative HUD style: a simple Apple-style slider at the left edge of
/// the screen, vertically centred – one rounded bar that fills from the
/// bottom, the symbol inside. Slides in on a key press, out after a moment.
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
    private static let size = CGSize(width: 64, height: 220)

    func show(kind: HUDModule.Kind, level: Float, muted: Bool) {
        let panel = panel ?? makePanel()
        if let screen = NSScreen.islandScreen(preferred: AppSettings.shared.displayID) {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.minX + 4, y: frame.midY - Self.size.height / 2,
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
    @ObservedObject private var cover = CoverAccent.shared

    private static let barSize = CGSize(width: 32, height: 176)
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let level = CGFloat(state.muted ? 0 : state.level)
        let filled = Self.barSize.height * level
        // The symbol sits at the bottom; once the fill covers it, it turns
        // dark on light fills so it stays readable.
        let symbolCovered = filled > 30 && !fillIsDark
        ZStack(alignment: .bottom) {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.35))
            Rectangle()
                .fill(fill)
                .frame(height: filled)
            Image(systemName: state.kind.symbol(level: state.level, muted: state.muted))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(symbolCovered ? Color.black.opacity(0.7) : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 16)
                .padding(.bottom, 9)
        }
        .frame(width: Self.barSize.width, height: Self.barSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: state.shown ? 0 : -60)
        .opacity(state.shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var fill: Color {
        state.kind.barColor(accent: settings.accentColor(cover: cover.color))
    }

    /// Only the accent colour (volume, coloured) is dark enough for a white symbol.
    private var fillIsDark: Bool {
        settings.hudBarColor == .colorful && state.kind == .volume
    }
}
