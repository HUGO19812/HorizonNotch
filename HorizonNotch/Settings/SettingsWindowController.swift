import AppKit
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, appearance, behavior
    case tabs, modules
    case music, lyrics, hud, battery, calendar, weather, shelf, connectivity, notifications, downloads, claude, lockScreen
    case permissions, about
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let selection = SettingsSelection()

    init(appDelegate: AppDelegate) {
        let root = SettingsView(appDelegate: appDelegate, selection: selection)
        let host = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = "Horizon Notch"
        window.setContentSize(NSSize(width: 740, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
    }

    func show(tab: SettingsTab) {
        selection.tab = tab
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        AppSettings.shared.onboardingDone = true
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}
