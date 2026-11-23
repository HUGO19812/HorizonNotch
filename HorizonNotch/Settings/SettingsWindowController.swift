import AppKit
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, appearance, behavior, displays
    case tabs, modules
    case music, lyrics, hud, battery, calendar, weather, shelf, connectivity, notifications, downloads, claude, lockScreen, light
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
        window.titleVisibility = .hidden
        window.title = "Horizon Notch"
        // Dark, see-through glass like Canopy: the SwiftUI view draws a
        // blurred background, the window itself stays clear.
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 780, height: 560))
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
