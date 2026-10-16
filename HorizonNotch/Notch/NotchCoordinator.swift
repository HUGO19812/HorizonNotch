import Combine
import SwiftUI

/// Decides what the island shows: which module owns the compact live
/// activity (highest priority wins: HUD > notification > timer > media) and
/// which pages the expanded island offers.
final class NotchCoordinator: ObservableObject {
    private(set) var modules: [any NotchModule] = []

    @Published private(set) var compactModule: (any NotchModule)?
    /// Short-lived modules (HUD, notifications) that also show while expanded.
    @Published private(set) var transientModule: (any NotchModule)?
    @Published private(set) var pages: [any NotchModule] = []
    @Published var pageIndex = 0

    private var subscriptions = Set<AnyCancellable>()
    private var recomputeScheduled = false
    private let settings = AppSettings.shared

    init() {
        settings.objectWillChange
            .sink { [weak self] in self?.scheduleRecompute() }
            .store(in: &subscriptions)
    }

    func register(_ module: any NotchModule) {
        modules.append(module)
        // objectWillChange fires before the value changes; look again on the
        // next run loop turn, coalescing bursts into one pass.
        module.objectWillChange
            .sink { [weak self] in self?.scheduleRecompute() }
            .store(in: &subscriptions)
        scheduleRecompute()
    }

    var currentPage: (any NotchModule)? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : pages.first
    }

    func showPage(offset: Int) {
        guard !pages.isEmpty else { return }
        pageIndex = (pageIndex + offset + pages.count) % pages.count
    }

    /// Called when the island opens: start on the first tab, or stay on the
    /// last one, as configured.
    func islandOpened() {
        if settings.openPage == .first { pageIndex = 0 }
    }

    func showPage(id: String) {
        if let index = pages.firstIndex(where: { $0.id == id }) { pageIndex = index }
    }

    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.recomputeScheduled = false
            self?.recompute()
        }
    }

    private func recompute() {
        let enabled = modules.filter { settings.isEnabled($0.id) }
        let active = enabled.filter(\.isActive).sorted { $0.priority > $1.priority }
        let newCompact = active.first
        let newTransient = active.first { $0.priority >= ModulePriority.notification }

        if newCompact?.id != compactModule?.id { compactModule = newCompact }
        if newTransient?.id != transientModule?.id { transientModule = newTransient }

        let order = settings.moduleOrder
        // User order first; modules not yet ordered keep registration order.
        let registered = modules.map(\.id)
        let rank: (any NotchModule) -> (Int, Int) = { module in
            (order.firstIndex(of: module.id) ?? Int.max, registered.firstIndex(of: module.id) ?? Int.max)
        }
        let newPages = enabled.filter { $0.hasExpandedContent && !settings.hiddenTabs.contains($0.id) }
            .sorted { rank($0) < rank($1) }
        if newPages.map(\.id) != pages.map(\.id) {
            let currentID = currentPage?.id
            pages = newPages
            pageIndex = newPages.firstIndex { $0.id == currentID } ?? 0
        }
        // The island's size depends on module state (e.g. wing width), so
        // the root view re-evaluates even when the owner stayed the same.
        objectWillChange.send()
    }
}
