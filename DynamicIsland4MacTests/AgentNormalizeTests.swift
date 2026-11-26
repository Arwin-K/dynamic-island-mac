import Foundation
import Testing
@testable import DynamicIsland4Mac

@MainActor
struct ClaudeCodeNormalizeTests {
    let provider = ClaudeCodeProvider()
    func kind(_ fixture: String) -> AgentEvent.Kind? { provider.normalize(Fixture.raw(fixture))?.kind }

    @Test func commonFields() throws {
        let event = try #require(provider.normalize(Fixture.raw("claude-session-start")))
        #expect(event.provider == "claude-code")
        #expect(event.sessionID == "c-123")
        #expect(event.cwd == "/Users/dev/code/notch-app")
        #expect(event.model == "claude-opus-5-5")
        #expect(event.transcriptPath?.hasSuffix("c-123.jsonl") == true)
        #expect(event.kind == .sessionStarted(source: "startup"))
    }

    @Test func mapsEveryEvent() {
        #expect(kind("claude-user-prompt") == .promptSubmitted(prompt: "Add a dark mode toggle"))
        #expect(kind("claude-pre-tool-bash") == .toolStarted(name: "Bash", detail: "Run tests"))
        #expect(kind("claude-pre-tool-edit") == .toolStarted(name: "Edit", detail: "App.swift"))
        #expect(kind("claude-post-tool-bash") == .toolFinished(name: "Bash"))
        #expect(kind("claude-permission-request") == .permissionRequested(tool: "Bash", detail: "rm -rf build"))
        #expect(kind("claude-notification-permission") == .permissionNotice(message: "Claude needs your permission to use Bash"))
        #expect(kind("claude-notification-idle") == .waitingForInput(message: nil))
        #expect(kind("claude-stop") == .stopped(lastMessage: "Added the toggle and all tests pass."))
        #expect(kind("claude-stop-failure") == .failed(error: "rate_limit"))
        #expect(kind("claude-subagent-start") == .subagentStarted(id: "a1"))
        #expect(kind("claude-subagent-stop") == .subagentStopped(id: "a1"))
        #expect(kind("claude-session-end") == .sessionEnded(reason: "prompt_input_exit"))
    }

    @Test func unknownEventsAreKeptAsOther() {
        #expect(kind("claude-unknown-event") == .other(name: "PostCompact"))
    }

    @Test func rejectsPayloadsWithoutSession() {
        #expect(provider.normalize(["hook_event_name": "Stop"]) == nil)
        #expect(provider.normalize(["session_id": "x"]) == nil)
        #expect(provider.normalize([:]) == nil)
    }

    @Test func permissionResponseFormat() throws {
        let allow = try JSONSerialization.jsonObject(with: provider.permissionResponse(.allow)) as? [String: Any]
        let hso = allow?["hookSpecificOutput"] as? [String: Any]
        #expect(hso?["hookEventName"] as? String == "PermissionRequest")
        #expect((hso?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let deny = try JSONSerialization.jsonObject(with: provider.permissionResponse(.deny(message: "no"))) as? [String: Any]
        let decision = (deny?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "no")
        #expect(decision?["updatedInput"] == nil)
    }
}

@MainActor
struct CodexNormalizeTests {
    let provider = CodexProvider()
    func kind(_ fixture: String) -> AgentEvent.Kind? { provider.normalize(Fixture.raw(fixture))?.kind }

    @Test func nullTranscriptPathIsFine() throws {
        let event = try #require(provider.normalize(Fixture.raw("codex-stop")))
        #expect(event.transcriptPath == nil)
        #expect(event.kind == .stopped(lastMessage: "The test was racing on a temp dir; fixed."))
        #expect(event.model == "gpt-5.5-codex")
    }

    @Test func mapsEveryEvent() {
        #expect(kind("codex-session-start") == .sessionStarted(source: "startup"))
        #expect(kind("codex-user-prompt") == .promptSubmitted(prompt: "Fix the flaky test"))
        #expect(kind("codex-pre-model") == .thinking)
        #expect(kind("codex-post-model-tokens") == .modelRequestFinished(tokens: TokenUsage(input: 1200, output: 340), error: nil))
        #expect(kind("codex-post-model-failed") == .modelRequestFinished(tokens: nil, error: "stream disconnected"))
        #expect(kind("codex-pre-tool") == .toolStarted(name: "Bash", detail: "cargo test"))
        #expect(kind("codex-post-tool") == .toolFinished(name: "Bash"))
        #expect(kind("codex-permission-request") == .permissionRequested(tool: "Bash", detail: "Force-push the branch"))
        #expect(kind("codex-interrupt") == .interrupted)
        #expect(kind("codex-subagent-start") == .subagentStarted(id: "sub-1"))
        #expect(kind("codex-session-end") == .sessionEnded(reason: "other"))
        #expect(kind("codex-unknown-event") == .other(name: "PostCompact"))
    }

    @Test func tokenUsageShapes() {
        #expect(CodexProvider.tokenUsage(["input": 5, "output": 6]) == TokenUsage(input: 5, output: 6))
        #expect(CodexProvider.tokenUsage(["total_tokens": 9])?.total == 9)
        #expect(CodexProvider.tokenUsage(NSNull()) == nil)
        #expect(CodexProvider.tokenUsage(["unrelated": 1]) == nil)
    }

    @Test func permissionResponseNeverIncludesReservedFields() throws {
        for decision in [PermissionDecision.allow, .deny(message: "Denied from the island")] {
            let object = try JSONSerialization.jsonObject(with: provider.permissionResponse(decision)) as? [String: Any]
            let d = (object?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
            #expect(d?["updatedInput"] == nil)
            #expect(d?["updatedPermissions"] == nil)
            #expect(d?["interrupt"] == nil)
        }
        let allow = String(decoding: provider.permissionResponse(.allow), as: UTF8.self)
        #expect(allow == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    }
}
