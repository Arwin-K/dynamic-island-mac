import SwiftUI

@main
struct DynamicIsland4MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item. Users can hide it (Settings → Behavior); relaunching the app from
        // Finder or Spotlight then opens Settings (see `AppDelegate.applicationShouldHandleReopen`).
        MenuBarExtra(isInserted: menuBarItemVisible) {
            MenuBarContent()
        } label: {
            Image(systemName: "capsule.inset.filled")
                .accessibilityLabel("DynamicIsland4Mac")
        }
    }

    private var menuBarItemVisible: Binding<Bool> {
        Binding(
            get: { AppServices.shared.preferences.values.showMenuBarItem && !AppPaths.isRunningTests },
            // Only write on a real change: Observation notifies on every assignment, even of an
            // equal value, and SwiftUI calls this setter during scene updates. Writing
            // unconditionally re-renders the scene, which calls the setter again, forever.
            set: { newValue in AppServices.shared.preferences.update { $0.showMenuBarItem = newValue } }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted in the app; don't create windows, servers or event taps then.
        guard !AppPaths.isRunningTests else { return }
        installSignalHandlers()
        // LSUIElement already makes us an accessory app; this guards against a stripped Info.plist.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            AppServices.shared.start()
        }
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) shows Settings. This is the way
    /// back in when the menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsOpener.open() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared.shutdown() }
    }

    /// `kill`, `pkill` and Xcode's Stop button send SIGTERM / SIGINT, which skip
    /// `applicationWillTerminate`. Catch them so the media adapter's child process is stopped
    /// instead of being orphaned.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { AppServices.shared.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
