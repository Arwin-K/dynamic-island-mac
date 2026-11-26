import SwiftUI

/// The status glyph shared by compact, list and alerts.
struct AgentStatusIndicator: View {
    let state: AgentState
    var accent: Color
    var size: CGFloat = 11
    var body: some View {
        Group {
            switch state {
            case .starting, .thinking:
                PulsingDot(color: accent)
                    .frame(width: size * 0.7, height: size * 0.7)
            case .runningTool(let tool):
                Image(systemName: Self.symbol(forTool: tool))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(accent)
            case .waitingForPermission:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.orange)
            case .waitingForInput:
                Image(systemName: "ellipsis.bubble.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.orange)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.red)
            case .interrupted:
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.gray)
            }
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel(state.label)
    }

    static func symbol(forTool tool: String) -> String {
        switch tool {
        case "Bash", "shell", "exec_command", "local_shell": "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": "pencil"
        case "Read", "view_image": "doc.text"
        case "Grep", "Glob", "LS": "magnifyingglass"
        case "WebFetch", "WebSearch", "web_search": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite", "update_plan": "checklist"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

struct ProviderIcon: View {
    let provider: AgentProvider?
    var size: CGFloat = 12
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Image(systemName: provider?.symbol(in: theme) ?? "sparkles")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(provider?.accent(in: theme) ?? .accentColor)
            .accessibilityLabel(provider?.displayName ?? "Agent")
    }
}

struct AgentCompactLeading: View {
    let module: AgentsModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if let top = module.liveSessions.first {
            let provider = module.provider(top.provider)
            HStack(spacing: 4) {
                ProviderIcon(provider: provider, size: 11)
                AgentStatusIndicator(state: top.state, accent: provider?.accent(in: theme) ?? .accentColor, size: 10)
            }
            .islandMatched("status", module: module.id)
        }
    }
}

struct AgentCompactTrailing: View {
    let module: AgentsModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        let live = module.liveSessions
        if let top = live.first {
            HStack(spacing: 4) {
                Text(top.projectName)
                    .font(theme.font(size: theme.typography.captionSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                if live.count > 1 {
                    Text("\(live.count)")
                        .font(theme.font(size: theme.typography.captionSize - 1, weight: .bold, monospacedDigits: true))
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(top.state.needsUser ? Color.orange.opacity(0.85) : palette.foreground.opacity(0.22)))
                        .accessibilityLabel("\(live.count) sessions")
                }
            }
        }
    }
}

/// The expanded list: every session from every provider.
struct AgentSessionList: View {
    let module: AgentsModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    private var prefs: PreferencesStore { module.context.services.preferences }

    var body: some View {
        let sessions = module.store.sorted
        VStack(spacing: 4) {
            HStack {
                Text(sessions.count == 1 ? "1 session" : "\(sessions.count) sessions")
                    .font(theme.captionFont)
                    .foregroundStyle(palette.secondary)
                Spacer()
                if sessions.contains(where: \.isStale) || sessions.contains(where: { !$0.state.isWorking && !$0.state.needsUser }) {
                    Button("Clear finished") {
                        module.store.removeAll { $0.isStale || (!$0.state.isWorking && !$0.state.needsUser) }
                    }
                    .buttonStyle(.plain)
                    .font(theme.captionFont)
                    .foregroundStyle(palette.secondary)
                }
                Button {
                    prefs.update { $0.agentGroupByProvider.toggle() }
                } label: {
                    Image(systemName: prefs.values.agentGroupByProvider ? "square.stack.3d.up" : "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain)
                .help(prefs.values.agentGroupByProvider ? "Grouped by provider" : "Sorted by urgency")
                .accessibilityLabel(prefs.values.agentGroupByProvider ? "Grouped by provider. Switch to sort by urgency." : "Sorted by urgency. Switch to group by provider.")
            }
            if sessions.isEmpty && module.approvals.pending.isEmpty {
                Text("No agent sessions right now")
                    .font(theme.bodyFont)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(module.approvals.pending) { request in
                            ApprovalCard(module: module, request: request)
                        }
                        if prefs.values.agentGroupByProvider {
                            ForEach(module.providers, id: \.id) { provider in
                                let group = sessions.filter { $0.provider == provider.id }
                                if !group.isEmpty {
                                    Text(provider.displayName)
                                        .font(theme.font(size: theme.typography.captionSize, weight: .semibold))
                                        .foregroundStyle(provider.accent(in: theme))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(group) { AgentSessionRow(module: module, session: $0) }
                                }
                            }
                        } else {
                            ForEach(sessions) { AgentSessionRow(module: module, session: $0) }
                        }
                    }
                }
            }
        }
    }
}

struct AgentSessionRow: View {
    let module: AgentsModule
    let session: AgentSession
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette
    @State private var hovering = false

    var body: some View {
        let provider = module.provider(session.provider)
        let accent = provider?.accent(in: theme) ?? palette.accent
        Button {
            provider?.focusSession(session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(accent.opacity(0.18))
                    ProviderIcon(provider: provider, size: 11)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.projectName)
                            .font(theme.font(size: theme.typography.bodySize, weight: theme.typography.titleWeight))
                            .lineLimit(1)
                        if let branch = session.gitBranch {
                            Text(branch)
                                .font(theme.captionFont)
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if session.subagentCount > 0 {
                            Label("\(session.subagentCount)", systemImage: "person.2.fill")
                                .labelStyle(.titleAndIcon)
                                .font(theme.captionFont)
                                .foregroundStyle(palette.secondary)
                        }
                        ElapsedText(since: session.startedAt, running: session.state.isWorking || session.state.needsUser)
                    }
                    HStack(spacing: 4) {
                        AgentStatusIndicator(state: session.state, accent: accent, size: 9)
                        Text(stateLine)
                            .font(theme.captionFont)
                            .foregroundStyle(session.state.needsUser ? Color.orange : palette.secondary)
                            .lineLimit(1)
                        if session.isStale {
                            Text("· no events for a while").font(theme.captionFont).foregroundStyle(palette.secondary)
                        }
                    }
                    if let message = session.lastAssistantMessage {
                        Text(message)
                            .font(theme.captionFont)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(2)
                    }
                    if module.context.services.preferences.values.agentShowTokenUsage, session.tokenUsage.total > 0 {
                        Text("\(Self.compact(session.tokenUsage.input)) in · \(Self.compact(session.tokenUsage.output)) out tokens")
                            .font(theme.timerFont)
                            .foregroundStyle(palette.secondary)
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.foreground.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider?.displayName ?? "Agent"), \(session.projectName), \(session.state.label)")
        .accessibilityHint("Brings its terminal to the front")
    }

    private var stateLine: String {
        switch session.state {
        case .waitingForPermission(let detail): "Needs permission · \(detail)"
        case .runningTool(let tool): session.currentTool == tool ? "Running \(tool)" : session.state.label
        case .failed(let error): "Failed · \(error)"
        default: session.state.label
        }
    }

    static func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}

/// "12:34" that ticks once a second only while the session is active.
struct ElapsedText: View {
    let since: Date
    let running: Bool
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: running ? 1 : 60)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(theme.timerFont)
                .foregroundStyle(palette.secondary)
        }
        .accessibilityLabel("Running for \(Self.format(Date().timeIntervalSince(since)))")
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct AgentAlertView: View {
    let module: AgentsModule
    let sessionID: String
    let transition: AgentSessionReducer.Transition
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        let session = module.store.sessions[sessionID]
        let provider = session.flatMap { module.provider($0.provider) }
        HStack(spacing: 10) {
            ProviderIcon(provider: provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(provider?.displayName ?? "Agent") · \(session?.projectName ?? "")")
                    .font(theme.titleFont)
                    .lineLimit(1)
                Text(detail)
                    .font(theme.captionFont)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let session { AgentStatusIndicator(state: session.state, accent: provider?.accent(in: theme) ?? palette.accent, size: 14) }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch transition {
        case .needsPermission(let detail): "Needs permission: \(detail)"
        case .waitingForInput: "Waiting for your input"
        case .finished: module.store.sessions[sessionID]?.lastAssistantMessage ?? "Finished"
        case .failed(let error): "Failed: \(error)"
        default: ""
        }
    }
}

struct AgentsModuleSettingsView: View {
    let context: ModuleContext

    var body: some View {
        ValueSlider(title: "Keep finished sessions in the compact island for", value: context.doubleBinding("keepFinishedMinutes", default: 10), range: 0...60, step: 1, format: "%.0f min")
        Button("Connect Claude Code and Codex…") { SettingsOpener.open(.agents) }
    }
}
