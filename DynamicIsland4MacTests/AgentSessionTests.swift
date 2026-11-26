import Foundation
import Testing
@testable import DynamicIsland4Mac

@MainActor
struct AgentSessionReducerTests {
    let claude = ClaudeCodeProvider()
    let codex = CodexProvider()

    /// Feed fixtures through normalize + reducer, collecting transitions.
    func run(_ provider: AgentProvider, _ fixtures: [String]) -> (AgentSession?, [AgentSessionReducer.Transition]) {
        var session: AgentSession?
        var all: [AgentSessionReducer.Transition] = []
        var t = Date(timeIntervalSince1970: 1_000)
        for name in fixtures {
            guard var event = provider.normalize(Fixture.raw(name)) else { continue }
            t += 1
            event.receivedAt = t
            let result = AgentSessionReducer.reduce(session, event)
            session = result.session
            all += result.transitions
        }
        return (session, all)
    }

    @Test func claudeTurnWithPermission() throws {
        let (session, transitions) = run(claude, [
            "claude-session-start", "claude-user-prompt", "claude-pre-tool-bash", "claude-post-tool-bash",
            "claude-permission-request", "claude-notification-permission", "claude-post-tool-bash", "claude-stop",
        ])
        let s = try #require(session)
        #expect(s.state == .done)
        #expect(s.lastAssistantMessage == "Added the toggle and all tests pass.")
        #expect(s.lastTool == "Bash")
        #expect(s.projectName == "notch-app")
        #expect(s.model == "claude-opus-5-5")
        // The later permission_prompt notification doesn't alert a second time.
        #expect(transitions == [.started, .needsPermission(detail: "Bash: rm -rf build"), .finished])
    }

    @Test func permissionNoticeAloneStillAlerts() {
        let (session, transitions) = run(claude, ["claude-session-start", "claude-user-prompt", "claude-notification-permission"])
        #expect(session?.state == .waitingForPermission("Claude needs your permission to use Bash"))
        #expect(transitions.last == .needsPermission(detail: "Claude needs your permission to use Bash"))
    }

    @Test func claudeIdleAfterStopMeansWaitingForInput() throws {
        let (session, transitions) = run(claude, ["claude-session-start", "claude-user-prompt", "claude-stop", "claude-notification-idle"])
        #expect(session?.state == .waitingForInput)
        #expect(transitions.last == .waitingForInput)
    }

    @Test func idleNotificationDoesNotInterruptWork() throws {
        let (session, _) = run(claude, ["claude-session-start", "claude-user-prompt", "claude-pre-tool-bash", "claude-notification-idle"])
        #expect(session?.state == .runningTool("Bash"))
    }

    @Test func claudeSubagentsAndEnd() {
        let (session, transitions) = run(claude, ["claude-session-start", "claude-subagent-start", "claude-subagent-start", "claude-subagent-stop"])
        #expect(session?.subagentCount == 1)
        let ended = AgentSessionReducer.reduce(session, claude.normalize(Fixture.raw("claude-session-end"))!)
        #expect(ended.session == nil)
        #expect(ended.transitions == [.ended])
        #expect(transitions == [.started])
    }

    @Test func claudeStopFailure() {
        let (session, transitions) = run(claude, ["claude-session-start", "claude-user-prompt", "claude-stop-failure"])
        #expect(session?.state == .failed("rate_limit"))
        #expect(transitions.last == .failed("rate_limit"))
    }

    @Test func codexTurnWithTokensAndNullTranscript() throws {
        let (session, transitions) = run(codex, [
            "codex-session-start", "codex-user-prompt", "codex-pre-model", "codex-post-model-tokens",
            "codex-pre-tool", "codex-post-tool", "codex-permission-request", "codex-pre-model", "codex-post-model-tokens", "codex-stop",
        ])
        let s = try #require(session)
        #expect(s.state == .done)
        #expect(s.transcriptPath == nil)
        #expect(s.tokenUsage == TokenUsage(input: 2400, output: 680))
        #expect(s.lastAssistantMessage == "The test was racing on a temp dir; fixed.")
        #expect(transitions == [.started, .needsPermission(detail: "Bash: Force-push the branch"), .finished])
    }

    @Test func codexFailedModelRequestThenRecovery() {
        let (failed, _) = run(codex, ["codex-session-start", "codex-user-prompt", "codex-post-model-failed"])
        #expect(failed?.state == .failed("stream disconnected"))
        let (recovered, _) = run(codex, ["codex-session-start", "codex-user-prompt", "codex-post-model-failed", "codex-pre-model"])
        #expect(recovered?.state == .thinking)
    }

    @Test func codexInterruptAndUnknownEvents() {
        let (session, _) = run(codex, ["codex-session-start", "codex-user-prompt", "codex-unknown-event", "codex-interrupt"])
        #expect(session?.state == .interrupted)
    }

    @Test func eventForUnseenSessionCreatesIt() {
        let (session, transitions) = run(codex, ["codex-pre-tool"])
        #expect(session?.state == .runningTool("Bash"))
        #expect(transitions == [.started])
    }

    @Test func storeKeepsProvidersSeparateAndSortsByUrgency() {
        let store = AgentSessionStore()
        var transitions: [AgentSessionReducer.Transition] = []
        store.onTransition = { _, t in transitions.append(t) }
        for name in ["claude-session-start", "claude-user-prompt", "claude-pre-tool-bash"] {
            store.apply(claude.normalize(Fixture.raw(name))!)
        }
        for name in ["codex-session-start", "codex-permission-request"] {
            store.apply(codex.normalize(Fixture.raw(name))!)
        }
        #expect(store.sessions.count == 2)
        #expect(store.sorted.first?.provider == "codex")
        #expect(store.needingUser.count == 1)
        store.apply(codex.normalize(Fixture.raw("codex-session-end"))!)
        #expect(store.sessions.count == 1)
        #expect(transitions.contains(.ended))
    }

    @Test func staleSessionsAreMarkedThenRemoved() {
        let store = AgentSessionStore()
        store.staleTimeoutMinutes = 1
        var event = codex.normalize(Fixture.raw("codex-session-start"))!
        event.receivedAt = Date(timeIntervalSince1970: 0)
        store.apply(event)
        store.sweep(now: Date(timeIntervalSince1970: 90))
        #expect(store.sessions.values.first?.isStale == true)
        store.sweep(now: Date(timeIntervalSince1970: 200))
        #expect(store.sessions.isEmpty)
    }

    @Test func terminalHeadersParse() {
        let info = AgentTerminalInfo(headers: ["x-di4m-term-program": "iTerm.app", "x-di4m-tty": "ttys004", "x-di4m-ppid": "123", "x-di4m-bundle": "", "x-di4m-iterm-session": "w0t1p0:ABC"])
        #expect(info.termProgram == "iTerm.app")
        #expect(info.tty == "ttys004")
        #expect(info.parentPID == 123)
        #expect(info.bundleID == nil)
        #expect(info.itermSessionID == "w0t1p0:ABC")
    }
}
