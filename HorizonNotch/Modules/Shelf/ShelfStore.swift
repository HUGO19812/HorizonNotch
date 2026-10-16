import AppKit
import Combine

/// Files parked in the island. Only references are kept (no copies); the
/// list survives restarts and drops entries whose file has disappeared.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []

    private let key = "shelfPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { url in !items.contains(where: { $0.path == url.path }) }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.path == url.path }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}

/// Sends files with the service chosen in the settings (AirDrop, Mail,
/// Messages).
enum Sharing {
    static func send(_ urls: [URL], via service: ShareService = AppSettings.shared.shareService) {
        guard !urls.isEmpty, let sharing = NSSharingService(named: service.serviceName) else { return }
        // The share window belongs to this app, so it has to come forward.
        NSApp.activate(ignoringOtherApps: true)
        if sharing.canPerform(withItems: urls) {
            sharing.perform(withItems: urls)
        }
    }
}

extension ShareService {
    var serviceName: NSSharingService.Name {
        switch self {
        case .airdrop: return .sendViaAirDrop
        case .mail: return .composeEmail
        case .messages: return .composeMessage
        }
    }

    var symbol: String {
        switch self {
        case .airdrop: return "dot.radiowaves.left.and.right"
        case .mail: return "envelope.fill"
        case .messages: return "message.fill"
        }
    }

    var title: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .mail: return L("Mail", "Mail")
        case .messages: return L("Nachrichten", "Messages")
        }
    }
}
