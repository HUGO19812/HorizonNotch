import AppKit
import Combine
import SwiftUI

/// Running downloads next to the notch (like Atoll). Browsers publish an
/// NSProgress for files they download into ~/Downloads – the same progress
/// the Dock's download stack shows. Subscribing to it needs no polling.
/// Shares the opt-in with the "finished downloads" notification because
/// macOS asks for access to the Downloads folder.
final class DownloadProgressModule: NotchModule {
    struct Item: Identifiable, Equatable {
        let id: ObjectIdentifier
        var name: String
        var fraction: Double
        var indeterminate: Bool
    }

    let id = "downloads"
    var title: String { L("Downloads", "Downloads") }
    let symbol = "arrow.down.circle.fill"
    let priority = ModulePriority.downloads
    let compactWingWidth: CGFloat = 92

    @Published private(set) var items: [Item] = []

    private var subscriber: Any?
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var subscription: AnyCancellable?
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    var isActive: Bool { !items.isEmpty }

    init() {
        subscription = AppSettings.shared.$notifyDownloads
            .sink { [weak self] on in DispatchQueue.main.async { on ? self?.start() : self?.stop() } }
    }

    private func start() {
        guard subscriber == nil else { return }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            self?.track(progress)
            return { [weak self] in
                DispatchQueue.main.async { self?.untrack(progress) }
            }
        }
    }

    private func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        observations.removeAll()
        items.removeAll()
    }

    private func track(_ progress: Progress) {
        let key = ObjectIdentifier(progress)
        // Throttle: fractionCompleted can change hundreds of times a second.
        var lastUpdate = Date.distantPast
        let observation = progress.observe(\.fractionCompleted, options: [.initial]) { [weak self] progress, _ in
            let now = Date()
            guard now.timeIntervalSince(lastUpdate) > 0.25 || progress.fractionCompleted >= 1 else { return }
            lastUpdate = now
            let item = Item(id: key,
                            name: Self.displayName(progress.fileURL),
                            fraction: progress.fractionCompleted,
                            indeterminate: progress.isIndeterminate)
            DispatchQueue.main.async { self?.update(item) }
        }
        DispatchQueue.main.async { self.observations[key] = observation }
    }

    private func update(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if items[index] != item { items[index] = item }
        } else {
            items.append(item)
        }
    }

    /// "file.zip.download" → "file.zip"; ordinary names stay as they are.
    private static func displayName(_ url: URL?) -> String {
        guard let url else { return L("Download", "Download") }
        let temporary = ["download", "crdownload", "part", "partial", "opdownload"]
        return temporary.contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    private func untrack(_ progress: Progress) {
        let key = ObjectIdentifier(progress)
        observations[key] = nil
        items.removeAll { $0.id == key }
    }

    #if DEBUG
    func debugDemo() {
        let key = ObjectIdentifier(self)
        items = [Item(id: key, name: "macOS-Handbuch", fraction: 0.42, indeterminate: false)]
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.items.removeAll() }
    }
    #endif

    func compactLeading() -> AnyView { AnyView(DownloadLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(DownloadTrailing(module: self)) }
}

private struct DownloadLeading: View {
    @ObservedObject var module: DownloadProgressModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let item = module.items.first
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: item?.indeterminate == false ? item?.fraction ?? 0 : 0.25)
                    .stroke(theme.tint(.blue), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: item?.fraction)
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            Text(item?.name ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
    }
}

private struct DownloadTrailing: View {
    @ObservedObject var module: DownloadProgressModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if module.items.count > 1 {
                Text("+\(module.items.count - 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let item = module.items.first {
                Text(item.indeterminate ? "…" : "\(Int((item.fraction * 100).rounded())) %")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.tint(.blue))
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }
}
