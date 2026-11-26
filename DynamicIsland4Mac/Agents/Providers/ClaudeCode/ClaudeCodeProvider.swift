import AppKit
import SwiftUI

/// Claude Code (CLI, IDE extensions). Hooks reference: https://code.claude.com/docs/en/hooks
///
/// Event mapping (Claude Code → common):
///
/// | Claude Code | Common |
/// |---|---|
/// | SessionStart | sessionStarted |
/// | UserPromptSubmit | promptSubmitted |
/// | PreToolUse (`tool_name`, `tool_input`) | toolStarted |
/// | PostToolUse / PostToolUseFailure | toolFinished / toolFailed |
/// | PermissionRequest | permissionRequested |
/// | Notification `permission_prompt` | permissionNotice (fires ~6 s after the prompt shows; only used if the request was missed) |
/// | Notification `idle_prompt` | waitingForInput (fires ~60 s after Claude finishes) |
/// | Stop (`last_assistant_message`) | stopped |
/// | StopFailure (`error`) | failed |
/// | SubagentStart / SubagentStop | subagent ± |
/// | SessionEnd | sessionEnded |
@MainActor
final class ClaudeCodeProvider: AgentProvider {
    let id = "claude-code"
    let displayName = "Claude Code"
    let symbolName = "asterisk"
    let defaultAccent = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// The events the installer registers, all as async (observe-only) command hooks.
    static let observedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd",
    ]


    private(set) lazy var installer: AgentHookInstaller = ClaudeCodeInstaller(provider: self)

    nonisolated func normalize(_ raw: [String: Any]) -> AgentEvent? {
        guard let sessionID = raw.string("session_id"), let name = raw.string("hook_event_name") else { return nil }
        let tool = raw.string("tool_name") ?? "tool"
        let kind: AgentEvent.Kind
        switch name {
        case "SessionStart":
            kind = .sessionStarted(source: raw.string("source"))
        case "UserPromptSubmit":
            kind = .promptSubmitted(prompt: raw.string("prompt").map { ToolSummary.truncate($0, to: 200) })
        case "PreToolUse":
            kind = .toolStarted(name: tool, detail: ToolSummary.detail(tool: tool, input: raw["tool_input"]))
        case "PostToolUse":
            kind = .toolFinished(name: tool)
        case "PostToolUseFailure":
            if raw["is_interrupt"] as? Bool == true { kind = .interrupted }
            else { kind = .toolFailed(name: tool, error: raw.string("error")) }
        case "PermissionRequest":
            kind = .permissionRequested(tool: tool, detail: ToolSummary.detail(tool: tool, input: raw["tool_input"]))
        case "Notification":
            switch raw.string("notification_type") {
            case "permission_prompt":
                kind = .permissionNotice(message: raw.string("message"))
            case "idle_prompt":
                kind = .waitingForInput(message: nil)
            default:
                kind = .other(name: "Notification:\(raw.string("notification_type") ?? "?")")
            }
        case "Stop":
            kind = .stopped(lastMessage: raw.string("last_assistant_message"))
        case "StopFailure":
            kind = .failed(error: raw.string("error") ?? "Unknown error")
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

    func focusSession(_ session: AgentSession) {
        TerminalFocuser.focus(session)
    }

    /// Claude Code's PermissionRequest output (hooks reference, "PermissionRequest"):
    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`,
    /// or `"behavior":"deny"` with a `message`. We never send `updatedInput`,
    /// `updatedPermissions` or `interrupt`: the island only approves exactly what was shown.
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
