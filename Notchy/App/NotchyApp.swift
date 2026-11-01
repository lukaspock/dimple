import SwiftUI

@main
struct NotchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows: the island lives in an NSPanel, controls in the status item.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let registry = ModuleRegistry()
    private var menuBar: MenuBarController?
    private var notchController: NotchWindowController?
    private var lockScreen: LockScreenController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registry.start()
        menuBar = MenuBarController()
        notchController = NotchWindowController(registry: registry)
        lockScreen = LockScreenController(registry: registry)
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stop()
    }
}
