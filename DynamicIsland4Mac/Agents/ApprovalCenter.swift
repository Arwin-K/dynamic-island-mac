import Foundation
import Observation

/// Opt-in: answer an agent's PermissionRequest from the island.
///
/// The agent's synchronous hook (`agent-hook.sh <provider> permission <seconds>`) waits on
/// `/permission`. We hold that HTTP request open until one of:
///
/// * the user clicks **Allow** or **Deny** → HTTP 200 with the provider's exact decision JSON;
/// * the timeout passes, the user answers in the terminal instead, the session ends, approvals
///   are off for that provider, the body is unreadable, or the app quits → HTTP 204 (or a
///   dropped connection), and the hook prints nothing so the agent shows its normal prompt.
///
/// Only an explicit click produces a decision. There is no code path that approves anything
/// automatically.
@MainActor
@Observable
final class ApprovalCenter {
    struct Pending: Identifiable {
        let id = UUID()
        let providerID: String
        let sessionKey: String
        let projectName: String
        /// The full tool name exactly as the agent reported it.
        let toolName: String
        /// The complete tool input, pretty-printed, shown before deciding.
        let input: String
        let createdAt: Date
        let expiresAt: Date
    }

    private(set) var pending: [Pending] = []
    @ObservationIgnored private var responders: [UUID: @Sendable (LocalServer.Response) -> Void] = [:]
    @ObservationIgnored private var timeouts: [UUID: DispatchWorkItem] = [:]
    /// Called when a new request needs the user (the Agents module alerts).
    @ObservationIgnored var onRequest: ((Pending) -> Void)?

    /// Registers a request and keeps its HTTP response open.
    func enqueue(providerID: String, raw: [String: Any], timeout: TimeInterval,
                 respond: @escaping @Sendable (LocalServer.Response) -> Void) {
        let sessionID = raw["session_id"] as? String ?? "unknown"
        let cwd = raw["cwd"] as? String
        let request = Pending(
            providerID: providerID,
            sessionKey: AgentSession.key(provider: providerID, sessionID: sessionID),
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project",
            toolName: raw["tool_name"] as? String ?? "Unknown tool",
            input: ToolSummary.fullInput(raw["tool_input"]),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(timeout)
        )
        pending.append(request)
        responders[request.id] = respond
        let work = DispatchWorkItem { [weak self] in self?.finish(request.id, response: .noContent, reason: "timed out") }
        timeouts[request.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        Log.agents.info("Approval requested by \(providerID, privacy: .public) for \(request.toolName, privacy: .public)")
        onRequest?(request)
    }

    /// The user clicked Allow or Deny.
    func decide(_ id: UUID, _ decision: PermissionDecision, provider: AgentProvider) {
        finish(id, response: LocalServer.Response(status: 200, body: provider.permissionResponse(decision)), reason: "\(decision)")
    }

    /// No decision: the agent falls back to its own prompt.
    func cancel(_ id: UUID, reason: String) {
        finish(id, response: .noContent, reason: reason)
    }

    /// Something happened in the session that means the prompt was answered elsewhere.
    func cancelAll(sessionKey: String, reason: String) {
        for request in pending where request.sessionKey == sessionKey { cancel(request.id, reason: reason) }
    }

    func cancelAll(reason: String) {
        for request in pending { cancel(request.id, reason: reason) }
    }

    /// Settings preview only: a request with nothing waiting on it.
    func insertPreview(_ request: Pending) { pending.append(request) }

    private func finish(_ id: UUID, response: LocalServer.Response, reason: String) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let respond = responders.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        respond(response)
        Log.agents.info("Approval \(id.uuidString, privacy: .public) finished: \(reason, privacy: .public)")
    }
}
