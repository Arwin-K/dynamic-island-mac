import SwiftUI

/// The menu shown from the menu bar item.
struct MenuBarContent: View {
    var body: some View {
        Button("Toggle Island") {
            AppServices.shared.screenManager.primaryIsland?.toggle()
        }
        Divider()
        Button("Settings…") { SettingsOpener.open() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit DynamicIsland4Mac") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
