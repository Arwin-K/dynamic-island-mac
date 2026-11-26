import AppKit
import SwiftUI

/// The Settings window. Managed with AppKit rather than a SwiftUI `Settings` scene so it can
/// be opened from anywhere (menu bar item, relaunching the app, module buttons) and so an
/// accessory app can bring it to the front reliably.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    let navigation = SettingsNavigation()

    func show(pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(navigation: navigation, services: AppServices.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "DynamicIsland4Mac Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = false
            window.setContentSize(NSSize(width: 860, height: 640))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("DynamicIsland4MacSettings")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppServices.shared.themeStore.flushPendingSave()
        AppServices.shared.preferences.saveNow()
    }
}

@MainActor
enum SettingsOpener {
    static func open(_ pane: SettingsPane? = nil) {
        SettingsWindowController.shared.show(pane: pane)
    }
}
