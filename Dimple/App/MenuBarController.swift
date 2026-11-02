import AppKit
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let loginItem = NSMenuItem(title: "Beim Login starten", action: #selector(toggleLogin), keyEquivalent: "")

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Dimple")
        loginItem.target = self
        let quit = NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(timerMenuItem())
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func timerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for minutes in [5, 10, 25] {
            let entry = NSMenuItem(title: "\(minutes) Minuten", action: #selector(startTimer(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = minutes
            submenu.addItem(entry)
        }
        let stopwatch = NSMenuItem(title: "Stoppuhr", action: #selector(startStopwatch), keyEquivalent: "")
        stopwatch.target = self
        submenu.addItem(stopwatch)
        item.submenu = submenu
        return item
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        TimerModule.shared.startPreset(minutes: sender.tag)
    }

    @objc private func startStopwatch() {
        TimerModule.shared.startStopwatch()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Dimple: login item change failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
