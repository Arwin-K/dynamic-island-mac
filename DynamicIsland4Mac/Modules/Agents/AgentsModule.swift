import Observation
import SwiftUI

/// Every running Claude Code and Codex session, side by side.
@MainActor
@Observable
final class AgentsModule: IslandModule {
    let id = "agents"
    let displayName = "Agent Sessions"
    let symbolName = "sparkles"
    let priority = 10

    let store: AgentSessionStore
    let providers: [AgentProvider]
    let approvals: ApprovalCenter
    @ObservationIgnored let context: ModuleContext
    /// Bumped when a finished session's "recently finished" window expires.
    private var expiryTick = 0
    @ObservationIgnored private var expiryWork: DispatchWorkItem?

    init(context: ModuleContext, store: AgentSessionStore, providers: [AgentProvider], approvals: ApprovalCenter) {
        self.context = context
        self.store = store
        self.providers = providers
        self.approvals = approvals
    }

    var keepFinishedMinutes: Double { context.double("keepFinishedMinutes", default: 10) }

    func provider(_ id: String) -> AgentProvider? { providers.first { $0.id == id } }

    /// Sessions worth showing in compact: working, needing the user, or finished recently.
    var liveSessions: [AgentSession] {
        _ = expiryTick
        let cutoff = Date().addingTimeInterval(-keepFinishedMinutes * 60)
        return store.sorted.filter { s in
            !s.isStale && (s.state.isWorking || s.state.needsUser || s.lastUpdate > cutoff)
        }
    }

    var isActive: Bool { !liveSessions.isEmpty || !approvals.pending.isEmpty }
    var showsInExpandedWhenIdle: Bool { !store.sessions.isEmpty || !approvals.pending.isEmpty }
    /// Room for the full approval card (input + buttons) while a decision is pending.
    var preferredExpandedHeight: Double? { approvals.pending.isEmpty ? nil : 250 }

    func start() {
        store.onTransition = { [weak self] session, transition in self?.handle(session, transition) }
        approvals.onRequest = { [weak self] request in self?.approvalRequested(request) }
        observeForExpiry()
    }

    func stop() {
        store.onTransition = nil
        approvals.onRequest = nil
        expiryWork?.cancel()
    }

    /// Schedules one wake-up for when the next finished session leaves the compact view
    /// (instead of polling).
    private func observeForExpiry() {
        withObservationTracking {
            _ = store.sessions
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleExpiry()
                self?.observeForExpiry()
            }
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryWork?.cancel()
        let window = keepFinishedMinutes * 60
        let next = store.sessions.values
            .filter { !$0.state.isWorking && !$0.state.needsUser }
            .map { $0.lastUpdate.addingTimeInterval(window) }
            .filter { $0 > Date() }
            .min()
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in self?.expiryTick += 1 }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSinceNow + 0.5, execute: work)
    }

    private func handle(_ session: AgentSession, _ transition: AgentSessionReducer.Transition) {
        let prefs = context.services.preferences.values.agentPreferences(for: session.provider)
        let feedback: FeedbackEvent
        switch transition {
        case .needsPermission:
            // With island approvals on, the approval request raises its own (sticky) alert.
            guard prefs.alertOnPermission, !prefs.approvalsEnabled else { return }
            feedback = .agentPermission
        case .waitingForInput:
            guard prefs.alertOnIdle else { return }
            feedback = .agentIdle
        case .finished:
            guard prefs.alertOnDone else { return }
            feedback = .agentDone
        case .failed:
            guard prefs.alertOnFailure else { return }
            feedback = .agentFailed
        case .started, .ended:
            return
        }
        let duration: TimeInterval? = feedback == .agentPermission ? 8 : nil
        context.alert(feedback: feedback, duration: duration, coalescingKey: session.id) { [weak self] in
            if let self { AgentAlertView(module: self, sessionID: session.id, transition: transition) }
        }
    }

    /// A sticky alert that stays until the request is decided or withdrawn; clicking it opens
    /// the island on the full request.
    private func approvalRequested(_ request: ApprovalCenter.Pending) {
        context.alert(feedback: .agentPermission, sticky: true, coalescingKey: request.sessionKey) { [weak self] in
            if let self { ApprovalAlertView(module: self, requestID: request.id) }
        }
        observeApproval(request.id, key: request.sessionKey)
    }

    /// Dismiss the sticky alert once the request is gone (decided, timed out, answered elsewhere).
    private func observeApproval(_ id: UUID, key: String) {
        withObservationTracking {
            _ = approvals.pending.contains { $0.id == id }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.approvals.pending.contains(where: { $0.id == id }) {
                    self.observeApproval(id, key: key)
                } else {
                    self.context.dismissAlerts(coalescingKey: key)
                }
            }
        }
    }

    func decide(_ request: ApprovalCenter.Pending, _ decision: PermissionDecision) {
        guard let provider = provider(request.providerID) else { return }
        approvals.decide(request.id, decision, provider: provider)
    }

    // MARK: Views

    func compactLeading() -> some View {
        AgentCompactLeading(module: self)
    }

    func compactTrailing() -> some View {
        AgentCompactTrailing(module: self)
    }

    func expanded() -> some View {
        AgentSessionList(module: self)
    }

    func settingsView() -> AnyView {
        AnyView(AgentsModuleSettingsView(context: context))
    }

    /// Fake Claude Code and Codex sessions for the Settings preview.
    static func preview(context: ModuleContext) -> AgentsModule {
        let store = AgentSessionStore()
        let now = Date()
        var claude = AgentSession(provider: "claude-code", sessionID: "preview-1", startedAt: now.addingTimeInterval(-754), lastUpdate: now)
        claude.cwd = "/Users/you/code/notch-app"
        claude.gitBranch = "feature/dark-mode"
        claude.state = .waitingForPermission("Bash: npm run build")
        claude.lastAssistantMessage = "I'll run the build to check the new toggle compiles."
        claude.subagentCount = 1
        var codex = AgentSession(provider: "codex", sessionID: "preview-2", startedAt: now.addingTimeInterval(-312), lastUpdate: now)
        codex.cwd = "/Users/you/code/api-server"
        codex.gitBranch = "main"
        codex.state = .runningTool("Bash")
        codex.currentTool = "Bash"
        codex.lastAssistantMessage = "Running the test suite after fixing the race."
        codex.tokenUsage = TokenUsage(input: 18_400, output: 2_150)
        var done = AgentSession(provider: "claude-code", sessionID: "preview-3", startedAt: now.addingTimeInterval(-2_100), lastUpdate: now)
        done.cwd = "/Users/you/code/blog"
        done.state = .done
        done.lastAssistantMessage = "Published the draft and fixed two broken links."
        for s in [claude, codex, done] { store.setPreview(s) }
        return AgentsModule(context: context, store: store, providers: AgentProviders.makeAll(), approvals: ApprovalCenter())
    }
}

extension AgentSessionStore {
    /// Settings preview only.
    func setPreview(_ session: AgentSession) { insertForPreview(session) }
}
