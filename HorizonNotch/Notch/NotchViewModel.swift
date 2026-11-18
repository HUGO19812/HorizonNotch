import AppKit
import Combine
import SwiftUI

enum IslandState: Equatable {
    case collapsed, compact, expanded
}

/// Outline parameters for one state of the island.
struct IslandLayout: Equatable {
    /// Size of the body, i.e. without the ears.
    var bodySize: CGSize
    var earRadius: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var visible: Bool

    var outerSize: CGSize { CGSize(width: bodySize.width + 2 * earRadius, height: bodySize.height) }
}

/// Island state: hover, expansion and the resulting layout.
final class NotchViewModel: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published private(set) var isExpanded = false
    /// Pointer rests on the island but it has not opened yet.
    @Published private(set) var isHovering = false
    /// Files are being dragged over the island: show the drop zones.
    @Published private(set) var isFileDragActive = false
    /// First launch: the open island says hello and stays open until
    /// "Get Started" is clicked.
    @Published var showHello = false
    /// Every later launch: a short "hello" that closes by itself.
    @Published var showGreeting = false
    /// Provides the drop zones; nil when the shelf module is missing.
    var shelf: ShelfModule?

    let coordinator: NotchCoordinator
    /// The drop beside the closed island (Claude next to the music).
    static let bubbleSize = CGSize(width: 76, height: 30)
    /// Size of the open island, from Settings → Appearance.
    static var expandedWidth: CGFloat { CGFloat(AppSettings.shared.islandWidth) }
    static var expandedContentHeight: CGFloat { CGFloat(AppSettings.shared.islandHeight) }

    init(geometry: NotchGeometry, coordinator: NotchCoordinator) {
        self.geometry = geometry
        self.coordinator = coordinator
    }

    var state: IslandState {
        if isExpanded || showGreeting { return .expanded }
        return coordinator.compactModule != nil ? .compact : .collapsed
    }

    var layout: IslandLayout { layout(for: state) }

    func layout(for state: IslandState) -> IslandLayout {
        let notch = geometry.notchSize
        let attached = geometry.hasNotch
        switch state {
        case .collapsed:
            let nudge: CGFloat = isHovering ? 1 : 0
            return IslandLayout(bodySize: CGSize(width: notch.width + 14 * nudge, height: notch.height + 3 * nudge),
                                earRadius: attached ? 6 : 0,
                                topRadius: attached ? 0 : notch.height / 2,
                                bottomRadius: attached ? 10 + 2 * nudge : notch.height / 2,
                                visible: attached || isHovering)
        case .compact:
            let wing = coordinator.compactModule?.compactWingWidth ?? 44
            let gap = attached ? notch.width : 28
            let grow: CGFloat = isHovering ? 6 : 0
            if let module = coordinator.compactModule, module.isPeeking {
                return IslandLayout(bodySize: CGSize(width: gap + 2 * wing + grow,
                                                     height: notch.height + module.peekHeight),
                                    earRadius: attached ? 8 : 0,
                                    topRadius: attached ? 0 : 18,
                                    // The device card is rounder, like a widget.
                                    bottomRadius: module.id == "devices" ? 26 : 16,
                                    visible: true)
            }
            return IslandLayout(bodySize: CGSize(width: gap + 2 * wing + grow, height: notch.height + grow / 2),
                                earRadius: attached ? 8 : 0,
                                topRadius: attached ? 0 : notch.height / 2,
                                bottomRadius: attached ? 13 : notch.height / 2,
                                visible: true)
        case .expanded:
            // The first-launch setup gets a larger stage.
            var width = showHello ? max(Self.expandedWidth, 600) : Self.expandedWidth
            var height = showHello ? 330 : Self.expandedContentHeight
            if showGreeting { width = 320; height = 104 }
            return IslandLayout(bodySize: CGSize(width: width,
                                                 height: notch.height + height),
                                earRadius: attached ? 14 : 0,
                                topRadius: attached ? 0 : 26,
                                bottomRadius: CGFloat(AppSettings.shared.islandCornerRadius),
                                visible: true)
        }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
    }

    func setFileDrag(_ active: Bool) {
        guard active != isFileDragActive else { return }
        isFileDragActive = active
        if active { setExpanded(true) }
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        if expanded { coordinator.islandOpened() }
        isExpanded = expanded
        if expanded { isHovering = false }
    }
}
