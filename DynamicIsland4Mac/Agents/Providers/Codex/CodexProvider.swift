import AppKit
import SwiftUI

/// OpenAI Codex (CLI and desktop app). Hooks reference: https://developers.openai.com/codex/hooks
///
/// Differences from Claude Code that matter here:
/// * There is **no Notification event**: "waiting for you" comes from PermissionRequest (which
///   only fires when approval is really needed) and Stop.
/// * `transcript_path` may be null, so the last message comes from Stop's `last_assistant_message`.
/// * PreModelRequest / PostModelRequest run for every model call (including retries);
///   PostModelRequest carries `status`, `error` and `token_usage`.
/// * Interrupt runs when the user interrupts a turn.
/// * SessionEnd always runs synchronously and Interrupt / SessionEnd hooks get 1–3 s, so the
///   hook script must return immediately (it does: it hands off to a detached curl).
@MainActor
final class CodexProvider: AgentProvider {
    let id = "codex"
    let displayName = "Codex"
    let symbolName = "chevron.left.forwardslash.chevron.right"
    let defaultAccent = Color(red: 0.06, green: 0.64, blue: 0.5)

    static let observedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "PreModelRequest", "PostModelRequest", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd",
    ]


    private(set) lazy var installer: AgentHookInstaller = CodexInstaller(provider: self)

    nonisolated func normalize(_ raw: [String: Any]) -> AgentEvent? {
        guard let sessionID = raw.string("session_id"), let name = raw.string("hook_event_name") else { return nil }
        let tool = raw.string("tool_name") ?? "tool"
        let kind: AgentEvent.Kind
        switch name {
        case "SessionStart":
            kind = .sessionStarted(source: raw.string("source"))
        case "UserPromptSubmit":
            kind = .promptSubmitted(prompt: raw.string("prompt").map { ToolSummary.truncate($0, to: 200) })
        case "PreModelRequest":
            kind = .thinking
        case "PostModelRequest":
            let status = raw.string("status")
            let error = status == "failed" ? (raw.string("error") ?? "Model request failed") : nil
            kind = .modelRequestFinished(tokens: Self.tokenUsage(raw["token_usage"]), error: error)
        case "PreToolUse":
            kind = .toolStarted(name: tool, detail: ToolSummary.detail(tool: tool, input: raw["tool_input"]))
        case "PostToolUse":
            kind = .toolFinished(name: tool)
        case "PermissionRequest":
            kind = .permissionRequested(tool: tool, detail: ToolSummary.detail(tool: tool, input: raw["tool_input"]))
        case "Stop":
            kind = .stopped(lastMessage: raw.string("last_assistant_message"))
        case "Interrupt":
            kind = .interrupted
        case "SubagentStart":
            kind = .subagentStarted(id: raw.string("agent_id"))
        case "SubagentStop":
            kind = .subagentStopped(id: raw.string("agent_id"))
        case "SessionEnd":
            kind = .sessionEnded(reason: raw.string("reason"))
        default:
            kind = .other(name: name)
        }
        return AgentEvent(
            provider: id, sessionID: sessionID, kind: kind, cwd: raw.string("cwd"), model: raw.string("model"),
            transcriptPath: raw.string("transcript_path"), agentID: raw.string("agent_id")
        )
    }

    /// The docs describe `token_usage` only as "token counts", so accept the common shapes:
    /// `{input_tokens, output_tokens}`, `{input, output}`, or just `{total_tokens}`.
    nonisolated static func tokenUsage(_ value: Any?) -> TokenUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        func int(_ keys: [String]) -> Int? {
            for key in keys { if let n = dict[key] as? NSNumber { return n.intValue } }
            return nil
        }
        let input = int(["input_tokens", "input", "prompt_tokens"])
        let output = int(["output_tokens", "output", "completion_tokens"])
        if input == nil, output == nil, let total = int(["total_tokens", "total"]) {
            return TokenUsage(input: total, output: 0)
        }
        guard input != nil || output != nil else { return nil }
        return TokenUsage(input: input ?? 0, output: output ?? 0)
    }

    func focusSession(_ session: AgentSession) {
        TerminalFocuser.focus(session)
    }

    /// Codex's PermissionRequest output: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
    /// "decision":{"behavior":"allow"}}}` or `"deny"` with a `message`. `updatedInput`,
    /// `updatedPermissions` and `interrupt` are reserved and make Codex fail closed, so they
    /// are never sent.
    nonisolated func permissionResponse(_ decision: PermissionDecision) -> Data {
        var inner: [String: Any]
        switch decision {
        case .allow: inner = ["behavior": "allow"]
        case .deny(let message): inner = ["behavior": "deny", "message": message]
        }
        let object: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": inner]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
