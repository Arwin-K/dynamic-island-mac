import SwiftUI

/// Settings → About.
struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "capsule.inset.filled")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("DynamicIsland4Mac").font(.title2.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Open source under the MIT License.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Privacy") {
                Text("No telemetry, no analytics, no network access. The only socket the app opens is a server bound to 127.0.0.1 that receives events from your local Claude Code and Codex hooks. Calendar events, media info and files on the shelf never leave your Mac.")
            }
            Section("Logs for bug reports") {
                Text("log stream --predicate 'subsystem == \"\(Log.subsystem)\"' --level debug")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Run this in Terminal, reproduce the problem, and attach the output to your issue. Logs are split by category: window, theme, modules, media, server, agents, installer, battery, hud, calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Third-party software") {
                Text("mediaremote-adapter by Jonas van den Berg and contributors, BSD 3-Clause License. See THIRD_PARTY_NOTICES.md in the repository.")
                    .font(.caption)
            }
            Section("Folders") {
                Button("Show Application Support Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                }
            }
        }
        .formStyle(.grouped)
    }
}
