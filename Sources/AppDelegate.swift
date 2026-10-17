import Cocoa
import ServiceManagement

/// The menu bar icon. A click starts a tidy (or brings back the plan page if one
/// is in progress); a right-click or Control-click shows the menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tidy = Tidy()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.toolTip = "Tab Tidy: click to tidy Chrome tabs, right-click for more"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon(busy: false)

        tidy.onPhaseChange = { [weak self] phase in
            self?.updateIcon(busy: phase == .thinking || phase == .applying)
        }
        tidy.onAlert = { [weak self] title, message in self?.alert(title, message) }
        tidy.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tidy.stop()
    }

    /// tabtidy://tidy does what a click on the icon does, for Shortcuts, hotkey apps and scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "tabtidy" }) { tidy.begin() }
    }

    private func updateIcon(busy: Bool) {
        let name = busy ? "hourglass" : "rectangle.stack"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tab Tidy")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            tidy.begin()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let busy = tidy.phase != .idle && tidy.phase != .failed
        menu.addItem(item(busy ? "Show Plan" : "Tidy Chrome Tabs", #selector(tidyNow)))

        let closed = History.load()
        if !closed.isEmpty {
            let noun = closed.count == 1 ? "Tab" : "Tabs"
            menu.addItem(item("Reopen \(closed.count) \(noun) From Last Tidy", #selector(reopen)))
        }
        if let summary = tidy.lastSummary {
            let info = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        menu.addItem(.separator())
        menu.addItem(item("Edit Extra Rules…", #selector(editRules)))
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tab Tidy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func tidyNow() { tidy.begin() }

    @objc private func reopen() { tidy.reopenLastClosed() }

    @objc private func editRules() {
        NSWorkspace.shared.open(Support.rulesFile())
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            alert("Couldn't change the login item", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
