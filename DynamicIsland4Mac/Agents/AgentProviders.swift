import Foundation

/// The registered agent providers. To add a tool (Gemini CLI, Cursor's agent, …), write a
/// class conforming to `AgentProvider` in `Providers/<Name>/` and add it here.
@MainActor
enum AgentProviders {
    static func makeAll() -> [AgentProvider] {
        [ClaudeCodeProvider(), CodexProvider()]
    }
}
