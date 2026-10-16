import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// File shelf with a send target (AirDrop, Mail or Messages). Dragging files
/// towards the notch opens both as drop targets; parked files stay until
/// they are dragged out again.
final class ShelfModule: NotchModule {
    let id = "shelf"
    var title: String { L("Ablage", "Shelf") }
    let symbol = "tray.full.fill"
    let priority = ModulePriority.media - 10
    let hasExpandedContent = true

    let store = ShelfStore()
    private var subscription: AnyCancellable?

    init() {
        subscription = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // The shelf has no live activity; its contents live on its page.
    var isActive: Bool { false }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(ShelfLayout(store: store, dragging: false, onDone: nil)) }

    /// Drop zones shown while files are dragged over the island.
    func dropZones(onDone: @escaping (_ toShelf: Bool) -> Void) -> AnyView {
        AnyView(ShelfLayout(store: store, dragging: true, onDone: onDone))
    }

    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

// MARK: - Layout

/// A small square with the send method (AirDrop, Mail, …) and a long field
/// for the parked files. The same layout serves the shelf page and the drop
/// targets while files are dragged over the island.
private struct ShelfLayout: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject private var settings = AppSettings.shared
    let dragging: Bool
    let onDone: ((Bool) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 10) {
                ShareSquare(service: settings.shareService, dragging: dragging, hasItems: !store.items.isEmpty,
                            send: { Sharing.send(store.items) },
                            drop: { urls in
                                Sharing.send(urls)
                                onDone?(false)
                            })
                    .frame(width: proxy.size.height, height: proxy.size.height)
                ShelfField(store: store, dragging: dragging) { urls in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.add(urls) }
                    onDone?(true)
                }
            }
        }
    }
}

private struct ShareSquare: View {
    let service: ShareService
    let dragging: Bool
    let hasItems: Bool
    let send: () -> Void
    let drop: ([URL]) -> Void
    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let active = targeted || (hovering && hasItems)
        Button(action: send) {
            VStack(spacing: 8) {
                Image(systemName: service.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .symbolEffect(.bounce, value: targeted)
                Text(service.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? theme.accent : .white.opacity(hasItems || dragging ? 0.85 : 0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Zone(dashed: dragging, highlighted: active, tint: theme.accent))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!hasItems && !dragging)
        .onHover { hovering = $0 }
        .help(hasItems ? L("Alle abgelegten Dateien senden", "Send all parked files") : service.title)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            ShelfModule.loadURLs(from: providers) { urls in if !urls.isEmpty { drop(urls) } }
            return true
        }
        .scaleEffect(targeted ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
    }
}

private struct ShelfField: View {
    @ObservedObject var store: ShelfStore
    let dragging: Bool
    let drop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: dragging ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 24, weight: .semibold))
                        .symbolEffect(.bounce, value: targeted)
                    Text(dragging ? L("Hier ablegen", "Drop to keep")
                                  : L("Dateien auf die Notch ziehen, um sie hier abzulegen",
                                      "Drag files onto the notch to keep them here"))
                        .font(.system(size: 11, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(targeted ? .white : .white.opacity(0.5))
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.items, id: \.path) { url in
                            ShelfItem(url: url) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.remove(url) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                }
                if !dragging {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.clear() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(PressScaleStyle())
                    .help(L("Ablage leeren", "Clear shelf"))
                    .padding(8)
                }
            }
        }
        .background(Zone(dashed: dragging, highlighted: targeted, tint: .white))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            ShelfModule.loadURLs(from: providers) { urls in if !urls.isEmpty { drop(urls) } }
            return true
        }
    }
}

/// Rounded field; dashed while a drag is in progress.
private struct Zone: View {
    let dashed: Bool
    let highlighted: Bool
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        shape.fill(tint.opacity(highlighted ? 0.16 : 0.06))
            .overlay(shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [6, 5] : []))
                .foregroundStyle(highlighted ? tint.opacity(0.9) : .white.opacity(dashed ? 0.3 : 0.08)))
            .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

private struct ShelfItem: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 52, height: 52)
            Text(url.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 74)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .overlay(FileDragSourceView(url: url, onDraggedOut: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { onRemove() }
        }))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(url.path)
        .transition(.scale.combined(with: .opacity))
    }
}
