import AppKit
import EventKit
import SwiftUI

/// Settings → Permissions: every permission the app can use, why, its status, and a button.
/// Nothing is requested until the feature that needs it is turned on.
struct PermissionsSettingsView: View {
    let services: AppServices
    @State private var automation: [String: AutomationStatus] = [:]
    @State private var accessibility = HUDService.isTrusted
    @State private var calendar = EKEventStore.authorizationStatus(for: .event)

    enum AutomationStatus { case granted, denied, notAsked, notInstalled }

    static let automationTargets: [(name: String, bundleID: String, why: String)] = [
        ("Terminal", "com.apple.Terminal", "Jumps to an agent's tab."),
        ("iTerm2", "com.googlecode.iterm2", "Jumps to an agent's tab."),
        ("Music", "com.apple.Music", "Media fallback if the adapter stops working."),
        ("Spotify", "com.spotify.client", "Media fallback if the adapter stops working."),
    ]

    var body: some View {
        Form {
            Section {
                row(title: "Accessibility", why: "Needed only by the Volume & Brightness module, to intercept those keys.",
                    granted: accessibility, status: accessibility ? "Granted" : "Not granted") {
                    HUDService.requestTrust()
                    HUDService.openAccessibilitySettings()
                }
                row(title: "Calendars", why: "Needed only by the Calendar module, to show your next event.",
                    granted: calendar == .fullAccess, status: calendarLabel) {
                    if calendar == .notDetermined {
                        EKEventStore().requestFullAccessToEvents { _, _ in
                            DispatchQueue.main.async { calendar = EKEventStore.authorizationStatus(for: .event) }
                        }
                    } else {
                        CalendarModule.openPrivacySettings()
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Turning a module off doesn't revoke a permission; remove it in System Settings → Privacy & Security if you like.")
            }

            Section {
                ForEach(Self.automationTargets, id: \.bundleID) { target in
                    let status = automation[target.bundleID] ?? .notAsked
                    if status != .notInstalled {
                        LabeledContent {
                            Text(label(status)).foregroundStyle(status == .granted ? .green : (status == .denied ? .red : .secondary))
                        } label: {
                            Text(target.name)
                            Text(target.why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Open Automation Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } header: {
                Text("Automation (Apple Events)")
            } footer: {
                Text("macOS asks the first time the app controls each of these. VS Code, Cursor, Ghostty, Warp and the Codex app need no permission: they're opened by URL or activated.")
            }

            Section("Not needed") {
                Text("No Screen Recording, Microphone, Input Monitoring, Full Disk Access or network permission. The app talks only to 127.0.0.1.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var calendarLabel: String {
        switch calendar {
        case .fullAccess: "Granted"
        case .notDetermined: "Not requested"
        case .writeOnly: "Write-only (needs full access)"
        default: "Denied"
        }
    }

    private func label(_ status: AutomationStatus) -> String {
        switch status {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notAsked: "Not asked yet"
        case .notInstalled: ""
        }
    }

    @ViewBuilder
    private func row(title: String, why: String, granted: Bool, status: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack {
                Text(status).foregroundStyle(granted ? .green : .secondary)
                if !granted { Button("Grant…", action: action) }
            }
        } label: {
            Text(title)
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        accessibility = HUDService.isTrusted
        calendar = EKEventStore.authorizationStatus(for: .event)
        // Checking automation status can block briefly, so do it off the main thread.
        Task.detached {
            var result: [String: AutomationStatus] = [:]
            for target in Self.automationTargets {
                result[target.bundleID] = Self.automationStatus(bundleID: target.bundleID)
            }
            await MainActor.run { automation = result }
        }
    }

    /// Asks macOS whether we may send Apple Events to an app, without prompting.
    nonisolated static func automationStatus(bundleID: String) -> AutomationStatus {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return .notInstalled }
        var desc = AEAddressDesc()
        let id = bundleID.utf8CString
        let created = id.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count - 1, &desc)
        }
        guard created == noErr else { return .notAsked }
        defer { AEDisposeDesc(&desc) }
        switch AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }
}
