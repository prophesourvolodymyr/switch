import AppKit

@MainActor
final class StatusBarController {
    private var item: NSStatusItem

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configure(item)
        item.isVisible = !SwitchPreferences.shared.hideMenuBarIcon
    }

    private func configure(_ item: NSStatusItem) {
        if let button = item.button {
            let img = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "SwitchinTosh")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "SwitchinTosh", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About SwitchinTosh", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SwitchinTosh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
    }

    // Showing recreates the item: macOS won't reliably bring back an icon the user dragged off via isVisible alone.
    func setHidden(_ hidden: Bool) {
        if hidden {
            item.isVisible = false
        } else {
            NSStatusBar.system.removeStatusItem(item)
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            configure(item)
            item.isVisible = true
        }
    }

    @objc private func showOnboarding() {
        NotificationCenter.default.post(name: .switchShowOnboarding, object: nil)
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
    }

    @objc private func openAbout() {
        MainActor.assumeIsolated { AboutWindow.shared.show() }
    }
}

extension Notification.Name {
    static let switchShowOnboarding = Notification.Name("com.sanyamgarg.switch.showOnboarding")
}
