import SwiftUI

/// One AI coding tool (Claude Code, Codex, …). Adding a tool means adding one file that
/// conforms to this protocol, and one line in `AgentProviders.all`.
///
/// Everything provider-specific lives here: how its hook JSON maps onto `AgentEvent`, how
/// its hooks are installed, how to jump to its sessions, and the exact JSON it expects back
/// from a PermissionRequest hook. The UI never branches on provider beyond icon, name and color.
@MainActor
protocol AgentProvider: AnyObject {
    /// Stable id: also the argument passed to `agent-hook.sh` and the key in theme files.
    var id: String { get }
    var displayName: String { get }
    /// Default SF Symbol. Users can override it in the theme (`providers.<id>.symbol`).
    var symbolName: String { get }
    var defaultAccent: Color { get }

    /// Provider JSON (exactly what the hook received on stdin) → common event.
    /// Return nil for payloads that aren't worth tracking.
    nonisolated func normalize(_ raw: [String: Any]) -> AgentEvent?

    var installer: AgentHookInstaller { get }

    /// Bring the session's terminal tab or app to the front.
    func focusSession(_ session: AgentSession)

    /// The JSON to print from a synchronous PermissionRequest hook for a decision.
    /// Each tool documents its own format, so this is never shared between providers.
    nonisolated func permissionResponse(_ decision: PermissionDecision) -> Data
}

extension AgentProvider {
    var icon: Image { Image(systemName: symbolName) }

    /// The icon, honoring the theme's override.
    func symbol(in theme: Theme) -> String { theme.providers[id]?.symbol ?? symbolName }
    func accent(in theme: Theme) -> Color { theme.providers[id]?.accent?.color ?? defaultAccent }
}

/// What the user decided in the island.
enum PermissionDecision: Equatable, Sendable {
    case allow
    case deny(message: String)
}

/// Helpers for reading loosely typed hook JSON.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        guard let v = self[key] as? String, !v.isEmpty else { return nil }
        return v
    }

    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}

enum ToolSummary {
    /// A short, human description of what a tool call does, for the island.
    static func detail(tool: String, input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return (input as? String).map { truncate($0) } }
        // Codex permission prompts may carry a human description.
        if let description = input.string("description") { return truncate(description) }
        if let command = input.string("command") { return truncate(command) }
        for key in ["file_path", "path", "notebook_path"] {
            if let path = input.string(key) { return URL(fileURLWithPath: path).lastPathComponent }
        }
        for key in ["pattern", "query", "url", "prompt", "subagent_type"] {
            if let value = input.string(key) { return truncate(value) }
        }
        return nil
    }

    /// Full tool input as pretty JSON (for permission prompts, where the user must see everything).
    static func fullInput(_ input: Any?) -> String {
        guard let input else { return "" }
        if let string = input as? String { return string }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: input) }
        return String(decoding: data, as: UTF8.self)
    }

    static func truncate(_ s: String, to limit: Int = 140) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "…" : oneLine
    }
}

/// Fallback focus: activate the app that hosts the session (terminal, editor or Codex app).
@MainActor
enum AgentAppActivator {
    static func activate(_ session: AgentSession) {
        let bundleID = session.terminal.bundleID ?? bundleID(forTermProgram: session.terminal.termProgram)
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func bundleID(forTermProgram program: String?) -> String? {
        switch program {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "vscode": "com.microsoft.VSCode"
        default: nil
        }
    }
}
