import AppKit
import Combine
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
            // Only the content is clipped: Liquid Glass must stay out of
            // clips and shadows, or it is drawn offscreen and turns flat.
            .clipShape(shape)
            // Closed and with a live activity beside the notch it stays pure
            // black so it blends with the hardware notch; the chosen style
            // only applies to the open island.
            .background(IslandBackground(shape: shape, style: state == .expanded ? settings.appearance : .black,
                                         tint: Color(hex: settings.islandTintColor) ?? .black))
            .overlay {
                if settings.islandBorder && state == .expanded && settings.appearance != .glass {
                    shape.stroke(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .modifier(IslandShadow(enabled: !(state == .expanded && settings.appearance == .glass),
                                   strength: state == .expanded ? settings.islandShadow : 0,
                                   glow: state == .compact ? (coordinator.compactModule?.compactGlow ?? .clear) : .clear))
            // Claude Code beside the music: a small bubble right of the island.
            .overlay(alignment: .topTrailing) {
                if state == .compact, let bubble = coordinator.bubbleModule {
                    bubble.bubbleView()
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.black))
                        .shadow(color: bubble.compactGlow ?? .clear, radius: 8)
                        .offset(x: 38, y: max(0, (model.geometry.notchSize.height - 30) / 2))
                        .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
                }
            }
            .animation(spring, value: coordinator.bubbleModule?.id)
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
                    // A live activity or notice fades in and out softly.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))))
                    .opacity(state == .compact ? 1 : 0)
                    .scaleEffect(state == .compact ? 1 : 0.9, anchor: .top)
                    .allowsHitTesting(state == .compact)
                    .animation(.easeOut(duration: state == .compact ? 0.25 : 0.1), value: state)
            }
            if state == .expanded {
                ExpandedContent(model: model, coordinator: coordinator, onDropFinished: onDropFinished)
                    // On clear glass the content carries a soft shadow
                    // instead of a dark tint behind it.
                    .shadow(color: .black.opacity(settings.appearance == .glass ? 0.45 : 0), radius: 2.5, y: 0.5)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
                            .animation(spring.delay(0.05)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .animation(spring, value: coordinator.compactModule?.id)
    }
}

/// Drop shadow and a module's coloured glow under the island – left out
/// for Liquid Glass, which brings its own depth.
private struct IslandShadow: ViewModifier {
    let enabled: Bool
    let strength: Double
    let glow: Color

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: .black.opacity(strength), radius: 8 + 14 * strength, y: 4 + 6 * strength)
                // A module's glow while closed, e.g. orange when Claude needs you.
                .shadow(color: glow, radius: 17, y: 10)
        } else {
            content
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
    @ObservedObject private var wallpaper = Wallpaper.shared

    /// The island panel's top-left corner on its screen (it is centred at
    /// the top, see NotchWindowController.positionPanel).
    private var windowOrigin: CGPoint {
        CGPoint(x: (wallpaper.screenSize.width - NotchWindowController.panelSize.width) / 2, y: 0)
    }

    var body: some View {
        switch style {
        case .glass:
            // Black at the top so the island still grows out of the notch,
            // then clear Liquid Glass: on macOS 26 the system's own glass,
            // which bends whatever lies behind (windows too) like Canopy's.
            // Before macOS 26 a hand-made glass over the desktop picture.
            ZStack {
                if #available(macOS 26.0, *) {
                    // AppKit's own clear glass (NSGlassEffectView): it
                    // refracts the windows behind without the grey veil
                    // SwiftUI's glass gets in this always-inactive panel.
                    ClearGlassView(cornerRadius: shape.bottomRadius)
                        .padding(.horizontal, shape.earRadius)
                } else if wallpaper.image != nil {
                    ZStack {
                        WallpaperPiece(windowOrigin: windowOrigin)
                        WallpaperPiece(zoom: 1.1, windowOrigin: windowOrigin)
                            .brightness(0.05)
                            .mask {
                                shape.stroke(Color.white, lineWidth: 26)
                                    .blur(radius: 9)
                            }
                        shape.fill(Color.white.opacity(0.04))
                    }
                    .clipShape(shape)
                } else {
                    shape.fill(.ultraThinMaterial).opacity(0.5)
                }
                shape.fill(LinearGradient(stops: [.init(color: .black, location: 0),
                                                  .init(color: .black, location: 0.16),
                                                  .init(color: .black.opacity(0.55), location: 0.3),
                                                  .init(color: .clear, location: 0.5)],
                                          startPoint: .top, endPoint: .bottom))
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
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: peeking)
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
    /// Live info per page id, refreshed when a page changes (see infoChanges).
    @State private var infos: [String: HeaderInfo] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: model.geometry.notchSize.height)
                // The setup has its own layout below the notch.
                .opacity(model.showHello || model.showGreeting ? 0 : 1)
                .allowsHitTesting(!model.showHello && !model.showGreeting)
                .onAppear(perform: refreshInfos)
                .onReceive(infoChanges) { refreshInfos() }
                .onChange(of: settings.headerLiveInfo) { refreshInfos() }
                .onChange(of: coordinator.pages.map(\.id)) { refreshInfos() }
            ZStack {
                if model.showHello {
                    OnboardingView { NotificationCenter.default.post(name: .helloFinished, object: nil) }
                        .transition(.opacity)
                } else if model.showGreeting {
                    GreetingView()
                        .transition(.opacity)
                } else if model.isFileDragActive, let shelf = model.shelf {
                    shelf.dropZones(onDone: onDropFinished)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if let page = coordinator.currentPage {
                    page.expandedView()
                        .id(page.id)
                        .transition(.pageSlide(coordinator.pageDirection))
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
                    if transient.id == "devices" {
                        // A connected device covers the whole page as a
                        // card instead of squeezing into the small pill.
                        transient.transientView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                if settings.appearance == .glass {
                                    Color.clear
                                } else {
                                    Color.black
                                }
                            }
                            .id(transient.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        TransientStrip(module: transient)
                            .id(transient.id)
                            .transition(.offset(y: 12).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: coordinator.transientModule?.id)
        }
    }

    private var header: some View {
        let geometry = model.geometry
        // The header spans the open island minus its 20 pt padding; the
        // hardware notch covers the middle, so tabs must stay in the wings.
        let gap = geometry.hasNotch ? geometry.notchSize.width + 16 : 16
        let wing = max(0, (NotchViewModel.expandedWidth - 40 - gap) / 2)
        let pages = coordinator.pages
        let active = coordinator.pages.indices.contains(coordinator.pageIndex) ? coordinator.pageIndex : 0
        let split = TabSplit(count: pages.count, wing: wing,
                             trailingReserve: statusReserve, style: settings.headerIconStyle,
                             active: active,
                             labelWidth: settings.headerActiveLabel && pages.indices.contains(active)
                                ? TabIcon.labelWidth(pages[active].title) : 0,
                             infoWidths: pages.map { settings.headerLiveInfo ? TabIcon.infoWidth(infos[$0.id]) : 0 })

        if settings.headerIconStyle == .pageDots {
            return AnyView(dotsHeader(wing: wing, gap: gap))
        }
        return AnyView(HStack(spacing: 0) {
            HStack(spacing: TabSplit.spacing) {
                if coordinator.pages.count > 1 {
                    ForEach(0..<split.leading, id: \.self) { tab($0, split: split) }
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
                        ForEach(split.leading..<coordinator.pages.count, id: \.self) { tab($0, split: split) }
                    }
                }
                Spacer(minLength: 0)
                HeaderStatus()
            }
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 20))
    }

    /// Like Pro Notch: page dots on the left (hover shows the page's name,
    /// click switches), on the right the status capsule with the coffee
    /// cup and battery, then the gear.
    private func dotsHeader(wing: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if coordinator.pages.count > 1 {
                    PageDots(pages: coordinator.pages.map { PageDots.Page(title: $0.title, symbol: $0.symbol) },
                             index: coordinator.pageIndex, accent: theme.accent) { index in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { coordinator.pageIndex = index }
                    }
                } else if let page = coordinator.currentPage {
                    Text(page.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: gap)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                HeaderStatus(alwaysShowCup: true)
            }
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }

    /// Room the status icons and the gear take on the right wing.
    private var statusReserve: CGFloat {
        var width: CGFloat = 0
        if settings.keepAwakeIcon { width += 16 + 8 }
        if settings.batteryInHeader && PowerSource.shared.state.hasBattery {
            width += 30 + 8
        }
        if settings.headerStatusGroup && HeaderStatus.hasContent { width += HeaderStatus.groupPadding * 2 }
        return width
    }

    /// Fires (coalesced) whenever one of the pages changes.
    private var infoChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(coordinator.pages.map { $0.objectWillChange.map { _ in () }.eraseToAnyPublisher() })
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    private func refreshInfos() {
        var next: [String: HeaderInfo] = [:]
        if settings.headerLiveInfo {
            for page in coordinator.pages { next[page.id] = page.headerInfo }
        }
        if next != infos { infos = next }
    }

    private func tab(_ index: Int, split: TabSplit) -> some View {
        let page = coordinator.pages[index]
        let active = index == coordinator.pageIndex
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                coordinator.pageIndex = index
            }
        } label: {
            TabIcon(symbol: page.symbol, active: active,
                    style: settings.headerIconStyle, accent: theme.accent, namespace: tabNamespace,
                    width: split.tabWidth,
                    label: active && split.showLabel ? page.title : nil,
                    info: split.showInfo ? infos[page.id] : nil)
        }
        .buttonStyle(.plain)
        .help(page.title)
    }
}

/// How many tabs fit left of the notch; the rest continue right of it.
/// Every tab is an icon plus its extras (the active tab's name, live
/// info). If they don't fit, the icons get narrower, then the info and
/// finally the name are left out.
private struct TabSplit {
    static let spacing: CGFloat = 5
    let leading: Int
    let tabWidth: CGFloat
    let showLabel: Bool
    let showInfo: Bool

    init(count: Int, wing: CGFloat, trailingReserve: CGFloat, style: HeaderIconStyle,
         active: Int = 0, labelWidth: CGFloat = 0, infoWidths: [CGFloat] = []) {
        let preferred: CGFloat = style == .pill ? 26 : 22
        let trailing = max(0, wing - trailingReserve)
        let hasInfo = infoWidths.contains { $0 > 0 }

        func layout(_ width: CGFloat, label: Bool, info: Bool) -> Int? {
            func tab(_ i: Int) -> CGFloat {
                width + (info && infoWidths.indices.contains(i) ? infoWidths[i] : 0)
                    + (label && i == active ? labelWidth : 0)
            }
            var used: CGFloat = 0
            var lead = 0
            while lead < count, used + tab(lead) <= wing {
                used += tab(lead) + Self.spacing
                lead += 1
            }
            guard lead >= 1 || count == 0 else { return nil }
            var rest: CGFloat = 0
            for i in lead..<count { rest += tab(i) + (i > lead ? Self.spacing : 0) }
            return rest <= trailing ? lead : nil
        }

        var attempts: [(label: Bool, info: Bool)] = [(labelWidth > 0, hasInfo)]
        if hasInfo { attempts.append((labelWidth > 0, false)) }
        if labelWidth > 0 { attempts.append((false, false)) }
        for attempt in attempts {
            var width = preferred
            while width >= 16 {
                if let lead = layout(width, label: attempt.label, info: attempt.info) {
                    leading = lead
                    tabWidth = width
                    showLabel = attempt.label
                    showInfo = attempt.info
                    return
                }
                width -= 1
            }
        }
        // Nothing fits: narrowest icons, as many left as possible.
        tabWidth = 16
        leading = min(count, max(1, Int((wing + Self.spacing) / (16 + Self.spacing))))
        showLabel = false
        showInfo = false
    }
}

/// One tab in the header, in the style chosen under Appearance: the icon,
/// for the active tab optionally its name, and optionally live info.
private struct TabIcon: View {
    let symbol: String
    let active: Bool
    let style: HeaderIconStyle
    let accent: Color
    let namespace: Namespace.ID
    var width: CGFloat = 22
    var label: String? = nil
    var info: HeaderInfo? = nil

    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let infoFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    /// Extra width the name takes beside the icon.
    static func labelWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: labelFont]).width) + 10
    }

    /// Extra width the live info takes beside the icon (badges sit on it).
    static func infoWidth(_ info: HeaderInfo?) -> CGFloat {
        func measure(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: infoFont]).width) + 3
        }
        switch info {
        case nil, .badge: return 0
        case .text(let text): return measure(text)
        case .countdown(let date):
            return measure(abs(date.timeIntervalSinceNow) >= 3600 ? "0:00:00" : "00:00")
        case .elapsed(let date):
            return measure(abs(date.timeIntervalSinceNow) >= 3600 ? "0:00:00" : "00:00")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: width, height: 20)
                .overlay(alignment: .topTrailing) {
                    if case .badge(let count) = info {
                        Text("\(min(count, 99))")
                            .font(.system(size: 7, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Capsule().fill(accent))
                            .offset(x: 2, y: -1)
                    }
                }
            if let info { infoText(info) }
            if let label {
                Text(label)
                    .font(Font(Self.labelFont))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 2)
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(active ? .white : .white.opacity(0.4))
        .background {
            if active && (style == .pill || label != nil) {
                Capsule().fill(accent.opacity(0.35))
                    .matchedGeometryEffect(id: "activeTab", in: namespace)
            }
        }
        .overlay(alignment: .bottom) {
            if active && style == .dot && label == nil {
                Circle().fill(accent)
                    .frame(width: 4, height: 4)
                    .offset(y: 4)
                    .matchedGeometryEffect(id: "activeTab", in: namespace)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func infoText(_ info: HeaderInfo) -> some View {
        Group {
            switch info {
            case .text(let text):
                Text(text)
            case .countdown(let end):
                Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                    .foregroundStyle(accent)
            case .elapsed(let start):
                Text(start, style: .timer)
                    .foregroundStyle(accent)
            case .badge:
                EmptyView()
            }
        }
        .font(Font(Self.infoFont))
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 1)
        .padding(.trailing, 2)
    }
}

/// A HUD or notification that arrives while the island is open: a small
/// pill floating above the bottom edge of the page.
private struct TransientStrip: View {
    let module: any NotchModule

    var body: some View {
        module.transientView()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule().fill(Color(white: 0.1))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            }
            .fixedSize()
            .padding(.bottom, 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: module.id)
    }
}

/// Small status icons at the top right of the open island, optionally
/// together in a glass capsule.
private struct HeaderStatus: View {
    /// The page-dots header always shows the cup, in the capsule.
    var alwaysShowCup = false
    var alwaysGrouped = false
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var power = PowerSource.shared
    @Environment(\.islandTheme) private var theme

    static let groupPadding: CGFloat = 8

    static var hasContent: Bool {
        let settings = AppSettings.shared
        return settings.keepAwakeIcon || (settings.batteryInHeader && PowerSource.shared.state.hasBattery)
    }

    var body: some View {
        // Clean like iOS: no capsule around the icons any more.
        let grouped = alwaysGrouped
        icons
            .padding(.horizontal, grouped ? Self.groupPadding : 0)
            .frame(height: grouped ? 22 : nil)
            .background {
                if grouped {
                    Capsule().fill(Color.white.opacity(0.08))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
            }
    }

    private var icons: some View {
        HStack(spacing: 12) {
            if settings.keepAwakeIcon || alwaysShowCup {
                Button { awake.toggle() } label: {
                    Image(systemName: awake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(awake.isOn ? theme.tint(.orange) : .white.opacity(0.35))
                        .frame(height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(awakeHelp)
            }
            HeaderBattery()
        }
    }

    private var awakeHelp: String {
        guard awake.isOn else {
            return L("Wach bleiben (auch zugeklappt) – klicken zum Einschalten", "Stay awake (also with lid closed) – click to turn on")
        }
        guard let end = awake.endDate else {
            return L("Wach bleiben ist an – klicken zum Ausschalten", "Stay awake is on – click to turn off")
        }
        let time = end.formatted(date: .omitted, time: .shortened)
        return L("Wach bleiben bis \(time) – klicken zum Ausschalten", "Stay awake until \(time) – click to turn off")
    }
}

extension Notification.Name {
    /// "Get Started" in the first-launch greeting.
    static let helloFinished = Notification.Name("horizon.helloFinished")
}

/// Page dots like Pro Notch: the current page a short white bar, the
/// others small dots. Each one switches to its page. Hovering a dot opens
/// it in place into a small capsule with the page's symbol and name – no
/// bubble hanging over the page.
private struct PageDots: View {
    struct Page {
        let title: String
        let symbol: String
    }

    let pages: [Page]
    let index: Int
    let accent: Color
    let select: (Int) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(pages.indices, id: \.self) { i in
                dot(i)
                    .onTapGesture { select(i) }
                    .onHover { inside in
                        if inside { hovered = i } else if hovered == i { hovered = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: hovered)
    }

    private func dot(_ i: Int) -> some View {
        let active = i == index
        let open = hovered == i
        return HStack(spacing: 4) {
            if open {
                Image(systemName: pages[i].symbol)
                    .font(.system(size: 9, weight: .bold))
                Text(pages[i].title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(active ? Color.black : Color.white)
        .padding(.horizontal, open ? 8 : 0)
        .frame(width: open ? nil : (active ? 22 : 7), height: open ? 18 : 7)
        .background(Capsule().fill(active ? Color.white : Color.white.opacity(open ? 0.2 : 0.32)))
        .overlay {
            if open && !active {
                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

/// Switching pages: the new page slides in from the side you swiped to,
/// sharpening out of a blur, while the old one slides off the other way.
private struct PageSlide: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(x: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static func pageSlide(_ direction: Int) -> AnyTransition {
        let d = CGFloat(direction)
        return .asymmetric(
            insertion: .modifier(active: PageSlide(offset: 70 * d, blur: 10, opacity: 0, scale: 0.94),
                                 identity: PageSlide(offset: 0, blur: 0, opacity: 1, scale: 1)),
            removal: .modifier(active: PageSlide(offset: -50 * d, blur: 10, opacity: 0, scale: 0.94),
                               identity: PageSlide(offset: 0, blur: 0, opacity: 1, scale: 1)))
    }
}

@available(macOS 26.0, *)
private struct ClearGlassView: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .clear
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}
