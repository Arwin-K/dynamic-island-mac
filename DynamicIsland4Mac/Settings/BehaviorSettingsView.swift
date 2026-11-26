import AppKit
import SwiftUI

/// Settings → Behavior.
struct BehaviorSettingsView: View {
    let services: AppServices
    @State private var loginError: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var prefs: PreferencesStore { services.preferences }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { prefs.values[keyPath: keyPath] },
            set: { newValue in prefs.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    var body: some View {
        Form {
            Section("Opening") {
                Picker("Open the island with", selection: binding(\.openMode)) {
                    ForEach(Preferences.OpenMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Close when the pointer moves away", isOn: binding(\.closeOnMouseExit))
                ValueSlider(title: "Hover delay", value: services.themeStore.binding(\.motion.hoverDelay), range: 0...1.5, step: 0.05, format: "%.2f s")
                LabeledContent("Toggle shortcut") {
                    ShortcutRecorder(shortcut: binding(\.toggleShortcut))
                }
                Text("Clicking an alert or a live activity always opens it. When opened by click or shortcut, the island stays open until you click it again or click elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                Picker("Show the island on", selection: binding(\.displayMode)) {
                    ForEach(Preferences.DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if prefs.values.displayMode == .chosen {
                    Picker("Display", selection: binding(\.chosenDisplayName)) {
                        ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                    }
                }
                Text("Displays without a notch get a floating pill below the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide in full-screen apps", isOn: binding(\.hideInFullScreen))
                Toggle("Hide from screen sharing, screenshots and recordings", isOn: binding(\.hideFromScreenCapture))
                Toggle("Hide the floating pill when nothing is active", isOn: binding(\.hideWhenIdle))
            } header: {
                Text("Stepping Aside")
            } footer: {
                Text("macOS has no public way to tell that you're sharing your screen, so instead the island excludes itself from every capture: people watching your share never see it, while you still do.")
            }

            Section("App") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                if LaunchAtLogin.needsApproval {
                    HStack {
                        Text("Approve DynamicIsland4Mac in System Settings → General → Login Items.")
                            .foregroundStyle(.orange)
                        Button("Open") { LaunchAtLogin.openSystemSettings() }
                    }
                }
                if let loginError {
                    Label(loginError, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                Toggle("Show menu bar item", isOn: binding(\.showMenuBarItem))
                if !prefs.values.showMenuBarItem {
                    Text("To get back to Settings, open DynamicIsland4Mac again from Finder or Spotlight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
