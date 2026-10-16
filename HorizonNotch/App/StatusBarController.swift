import AppKit

/// Menu bar item; the only visible entry point besides the island.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Horizon Notch")
                ?? NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Horizon Notch")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    // Rebuilt on every open so the language setting applies immediately.
    func menuNeedsUpdate(_ menu: NSMenu) {
        KeepAwake.shared.refresh()
        menu.removeAllItems()
        menu.addItem(entry(L("Island öffnen", "Open Island"), #selector(toggleIsland), key: ""))
        let awake = entry(L("Wach bleiben (auch zugeklappt)", "Stay awake (also with lid closed)"), #selector(toggleAwake), key: "")
        awake.state = KeepAwake.shared.isOn ? .on : .off
        menu.addItem(awake)
        menu.addItem(.separator())
        if !Permissions.accessibilityGranted {
            menu.addItem(entry(L("Bedienungshilfen erlauben …", "Allow Accessibility …"), #selector(openPermissions), key: ""))
        }
        menu.addItem(entry(L("Einstellungen …", "Settings …"), #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(entry(L("Horizon Notch beenden", "Quit Horizon Notch"), #selector(quit), key: "q"))
    }

    private func entry(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleIsland() { appDelegate?.toggleIsland() }
    @objc private func openSettings() { appDelegate?.showSettings() }
    @objc private func openPermissions() { appDelegate?.showSettings(tab: .permissions) }
    @objc private func toggleAwake() { KeepAwake.shared.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
