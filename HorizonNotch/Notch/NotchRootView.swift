import SwiftUI

/// Fills the transparent panel; draws the island at the top centre.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var coordinator: NotchCoordinator
    var onDropFinished: (Bool) -> Void = { _ in }
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var cover = CoverAccent.shared

    private var spring: Animation {
        let speed = max(0.4, settings.animationSpeed)
        return .spring(response: 0.42 / speed, dampingFraction: 0.8, blendDuration: 0)
    }

    var body: some View {
        let state = model.state
        let layout = model.layout(for: state)
        let shape = NotchShape(earRadius: layout.earRadius, topRadius: layout.topRadius,
                               bottomRadius: layout.bottomRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                content(for: state)
                    .padding(.horizontal, layout.earRadius)
            }
            .frame(width: layout.outerSize.width, height: layout.outerSize.height, alignment: .top)
            .background(IslandBackground(shape: shape, style: state == .collapsed ? .black : settings.appearance,
                                         tint: Color(hex: settings.islandTintColor) ?? .black))
            .clipShape(shape)
            .overlay {
                if settings.islandBorder && state != .collapsed {
                    shape.stroke(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .shadow(color: .black.opacity(state == .expanded ? settings.islandShadow : 0),
                    radius: 8 + 14 * settings.islandShadow, y: 4 + 6 * settings.islandShadow)
            .opacity(layout.visible ? 1 : 0)
            .animation(spring, value: layout)
            .animation(spring, value: state)
            Spacer(minLength: 0)
        }
        .padding(.top, model.geometry.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.islandTheme, settings.theme(cover: cover.color))
        .environment(\.legibilityWeight, settings.boldText ? .bold : .regular)
        .fontDesign(settings.fontDesign.design)
    }

    /// The compact layer stays mounted and is faded by opacity: removing it
    /// with a transition while the island grows could leave it stuck on
    /// screen. The expanded layer is inserted and removed as usual.
    @ViewBuilder
    private func content(for state: IslandState) -> some View {
        ZStack(alignment: .top) {
            if let module = coordinator.compactModule {
                CompactContent(module: module, geometry: model.geometry,
                               wing: module.compactWingWidth, peeking: module.isPeeking)
                    .id(module.id)
                    .opacity(state == .compact ? 1 : 0)
                    .scaleEffect(state == .compact ? 1 : 0.9, anchor: .top)
                    .allowsHitTesting(state == .compact)
                    .animation(.easeOut(duration: state == .compact ? 0.25 : 0.1), value: state)
            }
            if state == .expanded {
                ExpandedContent(model: model, coordinator: coordinator, onDropFinished: onDropFinished)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
                            .animation(spring.delay(0.05)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
    }
}

/// Black fill, a colour of your choice, or Liquid Glass on macOS 26+
/// (material on older systems). Collapsed it is always black so it merges
/// with the hardware notch.
private struct IslandBackground: View {
    let shape: NotchShape
    let style: IslandAppearance
    let tint: Color

    var body: some View {
        switch style {
        case .glass:
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.black.opacity(0.45)))
            }
        case .tinted:
            // Black at the top so the island still grows out of the notch.
            shape.fill(LinearGradient(colors: [.black, tint], startPoint: .top, endPoint: .init(x: 0.5, y: 0.6)))
        case .black:
            shape.fill(Color.black)
        }
    }
}

/// Live activity: one wing left and one right of the hardware notch.
private struct CompactContent: View {
    let module: any NotchModule
    let geometry: NotchGeometry
    // Passed as values: SwiftUI only re-renders this view when its inputs
    // change, and the module reference itself stays the same.
    let wing: CGFloat
    let peeking: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                module.compactLeading()
                    .frame(width: wing, alignment: .center)
                Spacer(minLength: geometry.hasNotch ? geometry.notchSize.width : 28)
                module.compactTrailing()
                    .frame(width: wing, alignment: .center)
            }
            .frame(height: geometry.notchSize.height)
            if peeking {
                module.peekView()
                    .frame(height: module.peekHeight, alignment: .top)
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 2)
    }
}

/// Header row beside the notch, the current page, and a strip for a
/// transient HUD/notification that arrives while the island is open.
private struct ExpandedContent: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var coordinator: NotchCoordinator
    let onDropFinished: (Bool) -> Void
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.islandTheme) private var theme
    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: model.geometry.notchSize.height)
            ZStack {
                if model.isFileDragActive, let shelf = model.shelf {
                    shelf.dropZones(onDone: onDropFinished)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if let page = coordinator.currentPage {
                    page.expandedView()
                        .id(page.id)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    Text(L("Keine Module aktiv", "No modules enabled"))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                if let transient = coordinator.transientModule {
                    TransientStrip(module: transient)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var header: some View {
        let geometry = model.geometry
        // The header spans the open island minus its 20 pt padding; the
        // hardware notch covers the middle, so tabs must stay in the wings.
        let gap = geometry.hasNotch ? geometry.notchSize.width + 16 : 16
        let wing = max(0, (NotchViewModel.expandedWidth - 40 - gap) / 2)
        let split = TabSplit(count: coordinator.pages.count, wing: wing,
                             trailingReserve: statusReserve, style: settings.headerIconStyle)

        return HStack(spacing: 0) {
            HStack(spacing: TabSplit.spacing) {
                if coordinator.pages.count > 1 {
                    ForEach(0..<split.leading, id: \.self) { tab($0, width: split.tabWidth) }
                } else if let page = coordinator.currentPage {
                    Text(page.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: gap)
            HStack(spacing: 8) {
                if coordinator.pages.count > 1 && split.leading < coordinator.pages.count {
                    HStack(spacing: TabSplit.spacing) {
                        ForEach(split.leading..<coordinator.pages.count, id: \.self) { tab($0, width: split.tabWidth) }
                    }
                }
                Spacer(minLength: 0)
                HeaderStatus()
                Button {
                    // NSApp.delegate is SwiftUI's adaptor, not AppDelegate, so
                    // ask through a notification.
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Einstellungen", "Settings"))
            }
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }

    /// Room the status icons and the gear take on the right wing.
    private var statusReserve: CGFloat {
        var width: CGFloat = 22 + 8 // gear
        if settings.keepAwakeIcon { width += 16 + 8 }
        if settings.batteryInHeader && PowerSource.shared.state.hasBattery {
            width += 22 + 8 + (settings.batteryShowPercent ? 34 : 0)
        }
        return width
    }

    private func tab(_ index: Int, width: CGFloat) -> some View {
        let page = coordinator.pages[index]
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                coordinator.pageIndex = index
            }
        } label: {
            TabIcon(symbol: page.symbol, active: index == coordinator.pageIndex,
                    style: settings.headerIconStyle, accent: theme.accent, namespace: tabNamespace,
                    width: width)
        }
        .buttonStyle(.plain)
        .help(page.title)
    }
}

/// How many tabs fit left of the notch; the rest continue right of it.
/// If even both wings are too narrow, the tabs get narrower.
private struct TabSplit {
    static let spacing: CGFloat = 5
    let leading: Int
    let tabWidth: CGFloat

    init(count: Int, wing: CGFloat, trailingReserve: CGFloat, style: HeaderIconStyle) {
        let preferred: CGFloat = style == .pill ? 26 : 22
        let trailing = max(0, wing - trailingReserve)
        func fits(_ width: CGFloat, _ room: CGFloat) -> Int {
            max(0, Int((room + Self.spacing) / (width + Self.spacing)))
        }
        var width = preferred
        while width > 16 && fits(width, wing) + fits(width, trailing) < count {
            width -= 1
        }
        tabWidth = width
        leading = min(count, max(1, fits(width, wing)))
    }
}

/// One tab icon in the header, in the style chosen under Appearance.
private struct TabIcon: View {
    let symbol: String
    let active: Bool
    let style: HeaderIconStyle
    let accent: Color
    let namespace: Namespace.ID
    var width: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? .white : .white.opacity(0.4))
            .frame(width: width, height: 20)
            .background {
                if active && style == .pill {
                    Capsule().fill(accent.opacity(0.35))
                        .matchedGeometryEffect(id: "activeTab", in: namespace)
                }
            }
            .overlay(alignment: .bottom) {
                if active && style == .dot {
                    Circle().fill(accent)
                        .frame(width: 4, height: 4)
                        .offset(y: 4)
                        .matchedGeometryEffect(id: "activeTab", in: namespace)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct TransientStrip: View {
    let module: any NotchModule

    var body: some View {
        HStack(spacing: 10) {
            module.compactLeading()
            module.compactTrailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(white: 0.12)))
        .padding(.bottom, 10)
    }
}

/// Small status icons at the top right of the open island.
private struct HeaderStatus: View {
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if settings.keepAwakeIcon {
                Button { awake.toggle() } label: {
                    Image(systemName: awake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(awake.isOn ? theme.tint(.orange) : .white.opacity(0.4))
                        .frame(height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(awake.isOn
                      ? L("Wach bleiben ist an – klicken zum Ausschalten", "Stay awake is on – click to turn off")
                      : L("Wach bleiben (auch zugeklappt) – klicken zum Einschalten", "Stay awake (also with lid closed) – click to turn on"))
            }
            HeaderBattery()
        }
    }
}
