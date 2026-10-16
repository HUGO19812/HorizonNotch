import AppKit
import Combine
import SwiftUI

/// Owns the island panel: places it on the chosen screen, follows the
/// pointer (event monitors, no timers) and lets clicks through everywhere
/// except on the island itself.
final class NotchWindowController {
    static let panelSize = CGSize(width: 760, height: 300)

    let model: NotchViewModel
    private let coordinator: NotchCoordinator
    private let settings = AppSettings.shared
    private var panel: NotchPanel?
    private var screen: NSScreen?

    private var monitors: [Any] = []
    private var hoverTimer: DispatchWorkItem?
    private var collapseTimer: DispatchWorkItem?
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount
    private var dragCarriesFiles = false
    private var swipeAccumulator: CGFloat = 0
    private var swipeConsumed = false
    /// Called with +1 (swipe left = forward) or −1 for a swipe on the music tab.
    var onMediaSwipe: ((Int) -> Void)?
    #if DEBUG
    /// Keeps the island as it is regardless of the pointer (screenshots).
    var debugPinned = false
    #endif
    private var subscriptions = Set<AnyCancellable>()

    init(coordinator: NotchCoordinator, shelf: ShelfModule?) {
        self.coordinator = coordinator
        let screen = NSScreen.islandScreen(preferred: AppSettings.shared.displayID)
        self.screen = screen
        model = NotchViewModel(geometry: screen.map(NotchGeometry.init) ?? NotchGeometry.fallback,
                               coordinator: coordinator)
        model.shelf = shelf
    }

    func start() {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        let host = NSHostingView(rootView: NotchRootView(model: model, coordinator: coordinator,
                                                         onDropFinished: { [weak self] in self?.finishFileDrop(showShelf: $0) }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel
        positionPanel()
        panel.orderFrontRegardless()

        installMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenConfigurationChanged() }
            .store(in: &subscriptions)
        // The calculator takes keyboard focus; hand it back when the island
        // closes so typing goes to the app the user works in again.
        NotificationCenter.default.publisher(for: .islandWantsKeyboard)
            .sink { [weak self] _ in self?.panel?.makeKey() }
            .store(in: &subscriptions)
        model.$isExpanded
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                guard let panel = self?.panel, panel.isKeyWindow else { return }
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            .store(in: &subscriptions)
        settings.$displayID
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.screenConfigurationChanged() } }
            .store(in: &subscriptions)
        // Keep the click-through region in sync when a live activity
        // appears or changes size while the pointer is elsewhere.
        coordinator.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.updateMouseHandling(at: NSEvent.mouseLocation) } }
            .store(in: &subscriptions)
    }

    /// Opens the island programmatically (e.g. from the menu bar).
    func expand() {
        cancelTimers()
        model.setExpanded(true)
    }

    func collapse() {
        cancelTimers()
        model.setExpanded(false)
        updateMouseHandling(at: NSEvent.mouseLocation)
    }

    // MARK: - Placement

    private func screenConfigurationChanged() {
        screen = NSScreen.islandScreen(preferred: settings.displayID)
        if let screen { model.geometry = NotchGeometry(screen: screen) }
        positionPanel()
    }

    private func positionPanel() {
        guard let panel, let screen else { return }
        let frame = screen.frame
        let origin = CGPoint(x: frame.midX - Self.panelSize.width / 2,
                             y: frame.maxY - Self.panelSize.height)
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }

    /// Island rectangle in screen coordinates for a given state.
    private func islandRect(for state: IslandState) -> CGRect {
        guard let screen else { return .zero }
        let size = model.layout(for: state).outerSize
        let top = screen.frame.maxY - model.geometry.topInset
        var rect = CGRect(x: screen.frame.midX - size.width / 2, y: top - size.height,
                          width: size.width, height: size.height)
        if state == .collapsed && !model.geometry.hasNotch {
            // Without a notch the collapsed island is invisible; react to the
            // pointer touching the top edge around the centre.
            rect = CGRect(x: screen.frame.midX - 110, y: screen.frame.maxY - 8, width: 220, height: 8)
        }
        return rect
    }

    // MARK: - Pointer

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            if event.type == .leftMouseDragged { self?.fileDragMoved() }
            self?.pointerMoved()
        }) { monitors.append(global) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.fileDragEnded()
        }) { monitors.append(up) }
        // Locally only plain moves: while the user scrubs a slider the
        // island must stay open even if the pointer leaves it.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(local) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleMediaSwipe(event)
            return event
        }) { monitors.append(scroll) }
        if let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.handleClick()
            return event
        }) { monitors.append(click) }
    }

    private func pointerMoved() {
        guard !model.isFileDragActive else { return }
        #if DEBUG
        if debugPinned { return }
        #endif
        let location = NSEvent.mouseLocation
        let inside = updateMouseHandling(at: location)

        if inside {
            collapseTimer?.cancel()
            collapseTimer = nil
            guard !model.isExpanded, hoverTimer == nil else { return }
            model.setHovering(true)
            let work = DispatchWorkItem { [weak self] in
                self?.hoverTimer = nil
                self?.model.setExpanded(true)
                self?.updateMouseHandling(at: NSEvent.mouseLocation)
            }
            hoverTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: work)
        } else {
            hoverTimer?.cancel()
            hoverTimer = nil
            model.setHovering(false)
            guard model.isExpanded, collapseTimer == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.collapseTimer = nil
                self?.model.setExpanded(false)
                self?.updateMouseHandling(at: NSEvent.mouseLocation)
            }
            collapseTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    // MARK: - File drags from other apps

    /// A drag in another app that carries files and comes near the notch
    /// opens the drop zones. A new drag is recognised by the drag
    /// pasteboard's change count.
    private func fileDragMoved() {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != dragPasteboardCount {
            dragPasteboardCount = pasteboard.changeCount
            dragCarriesFiles = pasteboard.canReadObject(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true])
        }
        guard dragCarriesFiles, model.shelf != nil, settings.isEnabled("shelf") else { return }
        let zone = islandRect(for: .expanded).insetBy(dx: -30, dy: -40)
        if zone.contains(NSEvent.mouseLocation) {
            if !model.isFileDragActive {
                cancelTimers()
                model.setFileDrag(true)
            }
            panel?.ignoresMouseEvents = false
        } else if model.isFileDragActive {
            model.setFileDrag(false)
            collapse()
        }
    }

    private func fileDragEnded() {
        dragCarriesFiles = false
        dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        guard model.isFileDragActive else { return }
        // Give the drop handler a moment before the zones disappear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.model.isFileDragActive else { return }
            self.model.setFileDrag(false)
            if !self.updateMouseHandling(at: NSEvent.mouseLocation) { self.collapse() }
        }
    }

    /// Called by the drop zones once files were handled.
    func finishFileDrop(showShelf: Bool) {
        model.setFileDrag(false)
        if showShelf { coordinator.showPage(id: "shelf") }
        if !updateMouseHandling(at: NSEvent.mouseLocation) { collapse() }
    }

    /// Accepts mouse events only while the pointer is over the island.
    @discardableResult
    private func updateMouseHandling(at location: CGPoint) -> Bool {
        var rect = islandRect(for: model.state)
        // A little slack around an open island so it does not snap shut
        // when the pointer grazes its edge.
        if model.isExpanded { rect = rect.insetBy(dx: -8, dy: -8) }
        let inside = rect.contains(location)
        panel?.ignoresMouseEvents = !inside
        return inside
    }

    private func handleClick() {
        guard !model.isExpanded, updateMouseHandling(at: NSEvent.mouseLocation) else { return }
        expand()
    }

    /// Two-finger sideways swipe on the music tab: next/previous track or
    /// ±10 s (settings). Other tabs keep their own scrolling.
    private func handleMediaSwipe(_ event: NSEvent) {
        guard model.isExpanded, settings.musicGesture != .off, coordinator.currentPage?.id == "media",
              event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began {
            swipeAccumulator = 0
            swipeConsumed = false
        }
        guard event.phase == .changed || event.phase == .began, !swipeConsumed else { return }
        swipeAccumulator += event.scrollingDeltaX
        guard abs(swipeAccumulator) > 50, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        swipeConsumed = true
        // Natural scrolling: fingers moving left give negative deltas = forward.
        onMediaSwipe?(swipeAccumulator < 0 ? 1 : -1)
        if settings.scrollHaptics { TrackpadHaptics.click(level: settings.hapticLevel) }
    }

    private func cancelTimers() {
        hoverTimer?.cancel()
        hoverTimer = nil
        collapseTimer?.cancel()
        collapseTimer = nil
    }
}

extension NotchGeometry {
    static var fallback: NotchGeometry { NotchGeometry(screen: NSScreen.screens.first!) }
}
