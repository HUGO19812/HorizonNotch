import AppKit
import Combine
import SwiftUI

/// What you copied lately, as a page: text, pictures and files, newest on
/// top. Clicking an entry copies it again. Kept in memory only, never
/// written to disk; entries from password managers (marked concealed)
/// are skipped.
final class ClipboardModule: NotchModule {
    let id = "clipboard"
    var title: String { L("Zwischenablage", "Clipboard") }
    let symbol = "doc.on.clipboard"
    let priority = ModulePriority.media - 35
    let hasExpandedContent = true

    struct Entry: Identifiable, Equatable {
        enum Content: Equatable {
            case text(String)
            case image(NSImage)
            case files([URL])
        }
        let id = UUID()
        let content: Content
        let date: Date

        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
    }

    @Published private(set) var entries: [Entry] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    /// Our own copy-back must not land on top as a new entry.
    private var ignoreNextChange = false
    private static let limit = 30

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.3
    }

    var isActive: Bool { false }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(ClipboardView(module: self)) }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        guard AppSettings.shared.isEnabled(id) else { return }
        if ignoreNextChange { ignoreNextChange = false; return }
        let types = board.types ?? []
        // Password managers mark secrets; never keep those.
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return }
        var content: Entry.Content?
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            content = .files(urls)
        } else if let image = NSImage(pasteboard: board), types.contains(where: { [.png, .tiff].contains($0) }) {
            content = .image(image)
        } else if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            content = .text(text)
        }
        guard let content else { return }
        if case .text(let text) = content { entries.removeAll { $0.content == .text(text) } }
        entries.insert(Entry(content: content, date: Date()), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func copy(_ entry: Entry) {
        let board = NSPasteboard.general
        board.clearContents()
        switch entry.content {
        case .text(let text): board.setString(text, forType: .string)
        case .image(let image): board.writeObjects([image])
        case .files(let urls): board.writeObjects(urls as [NSURL])
        }
        ignoreNextChange = true
        // Move it to the top.
        entries.removeAll { $0.id == entry.id }
        entries.insert(Entry(content: entry.content, date: Date()), at: 0)
    }

    func remove(_ entry: Entry) { entries.removeAll { $0.id == entry.id } }
    func clear() { entries.removeAll() }
}

/// "Clipboard 2" with a menu, then one rounded row per entry: a small
/// preview, the text or kind, how long ago.
private struct ClipboardView: View {
    @ObservedObject var module: ClipboardModule
    @State private var copied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L("Zwischenablage", "Clipboard"))
                    .font(.system(size: 15, weight: .bold))
                Text("\(module.entries.count)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Menu {
                    Button(L("Alles löschen", "Clear all"), role: .destructive) { module.clear() }
                        .disabled(module.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 26, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if module.entries.isEmpty {
                Text(L("Kopiere etwas – es erscheint hier.", "Copy something – it shows up here."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(module.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, highlighted: index == 0)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func row(_ entry: ClipboardModule.Entry, highlighted: Bool) -> some View {
        Button {
            module.copy(entry)
            copied = entry.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == entry.id { copied = nil } }
        } label: {
            HStack(spacing: 12) {
                preview(entry)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(label(entry))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if copied == entry.id {
                    Label(L("Kopiert", "Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    TimelineView(.everyMinute) { _ in
                        Text(age(entry.date))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(highlighted ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("Entfernen", "Remove")) { module.remove(entry) }
        }
    }

    @ViewBuilder
    private func preview(_ entry: ClipboardModule.Entry) -> some View {
        switch entry.content {
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        case .files(let urls):
            Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "")).resizable().scaledToFit()
        case .text:
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func label(_ entry: ClipboardModule.Entry) -> String {
        switch entry.content {
        case .text(let text): return text.replacingOccurrences(of: "\n", with: " ")
        case .image: return L("Bild", "Picture")
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : L("\(urls.count) Dateien", "\(urls.count) files")
        }
    }

    private func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return L("jetzt", "now") }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours) h" : L("\(hours / 24) T", "\(hours / 24) d")
    }
}
