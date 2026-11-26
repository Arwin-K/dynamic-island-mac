import AppKit
import SwiftUI

/// Settings → Agents: connect Claude Code and Codex, server settings, per-provider alerts.
struct AgentsSettingsView: View {
    let services: AppServices
    @State private var pendingPlan: PendingPlan?
    @State private var refresh = 0

    struct PendingPlan: Identifiable {
        let id = UUID()
        let provider: AgentProvider
        let plan: InstallPlan
    }

    private var hub: AgentHub { services.agentHub }
    private var prefs: PreferencesStore { services.preferences }

    var body: some View {
        Form {
            serverSection
            ForEach(hub.providers, id: \.id) { provider in
                ProviderSection(services: services, provider: provider, refresh: $refresh) { plan in
                    pendingPlan = PendingPlan(provider: provider, plan: plan)
                }
            }
            Section("Display") {
                Toggle("Group sessions by provider (otherwise sort by urgency)", isOn: binding(\.agentGroupByProvider))
                Toggle("Show token usage when reported (Codex)", isOn: binding(\.agentShowTokenUsage))
                ValueSlider(title: "Mark sessions stale after", value: binding(\.agentStaleTimeoutMinutes), range: 5...240, step: 5, format: "%.0f min")
            }
            Section("Scope") {
                Text("Works with Claude Code in the terminal and IDE extensions, and with the Codex CLI and Codex desktop app. The Claude desktop and web apps have no hook system, so their conversations can't appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .sheet(item: $pendingPlan) { pending in
            InstallDiffSheet(provider: pending.provider, plan: pending.plan) { approved in
                defer { pendingPlan = nil; refresh += 1 }
                guard approved else { return }
                do {
                    try pending.provider.installer.apply(pending.plan)
                } catch {
                    errorAlert = error.localizedDescription
                }
            }
        }
        .alert("Couldn't change the hooks", isPresented: Binding(get: { errorAlert != nil }, set: { if !$0 { errorAlert = nil } })) {
            Button("OK") { errorAlert = nil }
        } message: {
            Text(errorAlert ?? "")
        }
    }

    @State private var errorAlert: String?

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { prefs.values[keyPath: keyPath] }, set: { v in prefs.update { $0[keyPath: keyPath] = v } })
    }

    private var serverSection: some View {
        Section {
            HStack {
                switch hub.serverState {
                case .running(let port):
                    Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case .stopped:
                    Label("Stopped", systemImage: "pause.circle").foregroundStyle(.secondary)
                }
                Spacer()
            }
            LabeledContent("Port") {
                TextField("Port", value: binding(\.serverPort), format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Local Server")
        } footer: {
            Text("Hooks send events to this port on 127.0.0.1 only, with a secret token from ~/Library/Application Support/DynamicIsland4Mac. Changing the port needs no reinstall: the hook script reads it from there.")
        }
    }
}

private struct ProviderSection: View {
    let services: AppServices
    let provider: AgentProvider
    @Binding var refresh: Int
    let onPlan: (InstallPlan) -> Void
    @State private var testResult: String?
    @State private var testing = false
    @State private var showManual = false
    @State private var planError: String?

    private var hub: AgentHub { services.agentHub }
    private var providerPrefs: AgentProviderPreferences { services.preferences.values.agentPreferences(for: provider.id) }

    private func prefBinding<Value>(_ keyPath: WritableKeyPath<AgentProviderPreferences, Value>) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { providerPrefs[keyPath: keyPath] },
            set: { v in services.preferences.update { $0.agentProviders[provider.id, default: AgentProviderPreferences()][keyPath: keyPath] = v } }
        )
    }

    var approvalTimeout: Int? { providerPrefs.approvalsEnabled ? Int(providerPrefs.approvalTimeoutSeconds) : nil }

    var body: some View {
        let installer = provider.installer
        let status = installer.status(lastEventAt: hub.lastEventAt[provider.id])
        Section {
            HStack {
                Image(systemName: provider.symbolName).foregroundStyle(provider.defaultAccent)
                Text(provider.displayName).font(.headline)
                Spacer()
                StatusBadge(status: status)
            }
            LabeledContent("File") {
                Text(installer.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let codex = installer as? CodexInstaller {
                CodexHomeRow(services: services, installer: codex, refresh: $refresh)
            }

            if status == .manualTOML, let codex = installer as? CodexInstaller {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your config.toml declares hooks inline. Codex warns when one folder mixes config.toml hooks and hooks.json, so add these tables to \(codex.configTOMLURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) yourself:")
                        .font(.callout)
                    SnippetView(text: codex.tomlSnippet(approvalTimeout: approvalTimeout))
                }
            }

            HStack {
                if status != .manualTOML {
                    if status.isInstalled {
                        if status == .outdated {
                            Button("Update…") { plan { try installer.planInstall(approvalTimeout: approvalTimeout) } }
                        }
                        Button("Disconnect…") { plan { try installer.planUninstall() } }
                    } else {
                        Button("Connect…") { plan { try installer.planInstall(approvalTimeout: approvalTimeout) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Button(testing ? "Sending…" : "Send Test Event") { sendTest() }
                    .disabled(testing)
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                }
                Spacer()
                Button(showManual ? "Hide Manual Setup" : "Manual Setup") { showManual.toggle() }
                    .buttonStyle(.link)
            }
            if let planError {
                Label(planError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            if (status == .needsTrust || status == .installed), let note = installer.postInstallNote {
                Label(note, systemImage: status == .needsTrust ? "checkmark.shield" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(status == .needsTrust ? .orange : .secondary)
            }
            if showManual {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add this under \"hooks\" in \(installer.fileURL.lastPathComponent) (merge with any hooks you already have):")
                        .font(.callout)
                    SnippetView(text: installer.manualSnippet(approvalTimeout: approvalTimeout))
                }
            }

            ApprovalsSettings(provider: provider, prefs: prefBinding(\.approvalsEnabled), timeout: prefBinding(\.approvalTimeoutSeconds),
                              installed: status.isInstalled, entryInstalled: (installer as? JSONHookInstaller)?.approvalEntryInstalled() ?? false) {
                plan { try installer.planInstall(approvalTimeout: approvalTimeout) }
            }

            Toggle("Show \(provider.displayName) sessions", isOn: prefBinding(\.enabled))
            Toggle("Alert when a session needs permission", isOn: prefBinding(\.alertOnPermission))
            Toggle(provider.id == "codex" ? "Alert when a session is waiting for input (Codex has no idle event; uses Stop)" : "Alert when a session is waiting for input",
                   isOn: prefBinding(\.alertOnIdle))
            Toggle("Alert when a session finishes", isOn: prefBinding(\.alertOnDone))
            Toggle("Alert when a session fails", isOn: prefBinding(\.alertOnFailure))
        }
    }

    private func plan(_ make: () throws -> InstallPlan) {
        do {
            planError = nil
            let plan = try make()
            if plan.changesNothing {
                planError = "Nothing to change."
            } else {
                onPlan(plan)
            }
        } catch {
            planError = error.localizedDescription
        }
    }

    private func sendTest() {
        testing = true
        testResult = nil
        hub.sendTestEvent(providerID: provider.id) { elapsed in
            testing = false
            if let elapsed {
                testResult = "✓ Round trip OK (\(Int(elapsed * 1000)) ms): hook script → app"
            } else {
                testResult = "✗ No event arrived. Is the server running?"
            }
        }
    }
}

private struct CodexHomeRow: View {
    let services: AppServices
    let installer: CodexInstaller
    @Binding var refresh: Int
    @State private var detecting = false

    var body: some View {
        LabeledContent("CODEX_HOME") {
            HStack {
                TextField(CodexHome.defaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), text: Binding(
                    get: { services.preferences.values.codexHomeOverride },
                    set: { value in
                        services.preferences.update { $0.codexHomeOverride = value }
                        installer.setCodexHome(CodexHome.resolveQuickly())
                    }
                ))
                .frame(maxWidth: 220)
                Button(detecting ? "Detecting…" : "Detect") {
                    detecting = true
                    Task.detached {
                        let found = CodexHome.resolveFromShell()
                        await MainActor.run {
                            detecting = false
                            if let found {
                                services.preferences.update { $0.codexHomeOverride = found.path }
                                installer.setCodexHome(found)
                            }
                            refresh += 1
                        }
                    }
                }
                .help("Reads $CODEX_HOME from launchd and your login shell. Apps opened from Finder don't see shell variables.")
            }
        }
    }
}

private struct StatusBadge: View {
    let status: InstallStatus

    var color: Color {
        switch status {
        case .receivingEvents: .green
        case .installed: .blue
        case .needsTrust, .outdated, .manualTOML: .orange
        case .notInstalled: .secondary
        case .error: .red
        }
    }

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct SnippetView: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

/// "Review the exact changes before anything is written."
struct InstallDiffSheet: View {
    let provider: AgentProvider
    let plan: InstallPlan
    let onDone: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.isUninstall ? "Disconnect \(provider.displayName)?" : "Connect \(provider.displayName)?")
                .font(.title2.bold())
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(plan.fileURL.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.diff.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .frame(minHeight: 240, maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button(plan.isUninstall ? "Remove Entries" : "Write Changes") { onDone(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private var summary: String {
        var parts: [String] = []
        if plan.originalText != nil {
            parts.append("The current file is backed up next to it as \(plan.fileURL.lastPathComponent).dynamicisland4mac-backup-<date> first.")
        } else if plan.newText != nil {
            parts.append("This file doesn't exist yet and will be created.")
        }
        parts.append(plan.isUninstall
            ? "Only the entries DynamicIsland4Mac added are removed. Your other hooks and settings stay exactly as they are."
            : "Entries are added at the end. Your existing hooks and settings are not removed or reordered.")
        if plan.newText == nil { parts.append("The file was created by DynamicIsland4Mac and is now empty, so it will be deleted.") }
        return parts.joined(separator: " ")
    }
}

private struct DiffLineView: View {
    let line: LineDiff.Line

    var body: some View {
        let (prefix, text, color): (String, String, Color) = {
            switch line {
            case .same(let s): return ("  ", s, .secondary)
            case .added(let s): return ("+ ", s, .green)
            case .removed(let s): return ("- ", s, .red)
            }
        }()
        Text(prefix + text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color == .secondary ? Color.clear : color.opacity(0.1))
    }
}

/// The opt-in approvals toggle with its warning, per provider.
private struct ApprovalsSettings: View {
    let provider: AgentProvider
    @Binding var prefs: Bool
    @Binding var timeout: Double
    let installed: Bool
    let entryInstalled: Bool
    let onUpdateHooks: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Approve \(provider.displayName) permission requests from the island", isOn: $prefs)
                if prefs {
                    ValueSlider(title: "Wait for a decision", value: $timeout, range: 10...120, step: 5, format: "%.0f s")
                }
                if installed && prefs != entryInstalled {
                    HStack {
                        Label(prefs ? "The hooks need updating to add the approval hook." : "The hooks still contain the approval hook.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Update Hooks…", action: onUpdateHooks)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text("Approve from the island")
                Spacer()
                Text(prefs ? "On" : "Off").foregroundStyle(prefs ? .orange : .secondary)
            }
        }
    }

    private var warning: String {
        var text = "When this is on, \(provider.displayName)'s PermissionRequest hook waits up to the time below for you to click Allow or Deny in the island. The island shows the provider, the full tool name and its complete input first. "
        text += "Allow lets that one tool call run exactly as shown; it never edits the input or adds permanent rules. If you don't decide in time, or the app isn't running, nothing is returned and \(provider.displayName) asks you in the terminal as usual. While it waits, the agent is paused."
        if provider.id == "codex" {
            text += " Turning this on or off changes your Codex hooks, so Codex will ask you to trust them again (/hooks)."
        }
        return text
    }
}
