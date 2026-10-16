import AppKit
import Combine
import SwiftUI

/// A short message shown next to the notch, e.g. "AirPods connected".
struct IslandEvent: Identifiable {
    let id = UUID()
    var symbol: String
    var tint: Color = .white
    var title: String
    var detail: String = ""
    /// Shown instead of the symbol when set (app or file icon).
    var image: NSImage?
    var duration: TimeInterval = 3.5
    /// Runs when the island is clicked while the event shows.
    var action: (() -> Void)?
}

/// Shows a queue of transient events one after another. Used for both the
/// connectivity and the notification module, so each can be switched off
/// on its own.
final class EventModule: NotchModule {
    let id: String
    private let titles: (de: String, en: String)
    var title: String { L(titles.de, titles.en) }
    let symbol: String
    let priority = ModulePriority.notification
    let compactWingWidth: CGFloat = 124

    @Published private(set) var current: IslandEvent?
    private var queue: [IslandEvent] = []
    private var hideWork: DispatchWorkItem?
    private let settings = AppSettings.shared

    init(id: String, title: (de: String, en: String), symbol: String) {
        self.id = id
        self.titles = title
        self.symbol = symbol
    }

    var isActive: Bool { current != nil }

    func post(_ event: IslandEvent) {
        guard settings.isEnabled(id) else { return }
        // Same subject already on screen: update it in place.
        if current?.title == event.title {
            current = event
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showNext() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + event.duration, execute: work)
            return
        }
        // Replace a queued event about the same thing instead of piling up.
        queue.removeAll { $0.title == event.title }
        queue.append(event)
        if current == nil { showNext() }
    }

    /// Ends the current event early (e.g. after its action ran).
    func dismiss() {
        hideWork?.cancel()
        showNext()
    }

    private func showNext() {
        guard !queue.isEmpty else {
            current = nil
            return
        }
        let event = queue.removeFirst()
        current = event
        let work = DispatchWorkItem { [weak self] in self?.showNext() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + event.duration, execute: work)
    }

    func compactLeading() -> AnyView { AnyView(EventLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(EventTrailing(module: self)) }
}

private struct EventLeading: View {
    @ObservedObject var module: EventModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let event = module.current {
                Group {
                    if let image = event.image {
                        Image(nsImage: image).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: event.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.tint(event.tint))
                            .symbolEffect(.bounce, value: event.id)
                    }
                }
                .frame(width: 20)
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .id(module.current?.id)
        .transition(.opacity.combined(with: .move(edge: .leading)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if let action = module.current?.action {
                action()
                module.dismiss()
            }
        }
    }
}

private struct EventTrailing: View {
    @ObservedObject var module: EventModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Text(module.current?.detail ?? "")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(theme.tint(module.current?.tint ?? .white).opacity(0.9))
            .lineLimit(1)
            .truncationMode(.tail)
            .id(module.current?.id)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
    }
}
