import Foundation

/// The shared session state machine: (current session, event) → new session + what happened.
///
/// Pure and provider-neutral, so it's unit tested with recorded hook JSON from both tools.
/// The store applies the result; the UI raises alerts from the transitions.
enum AgentSessionReducer {
    /// Notable changes the UI may alert on.
    enum Transition: Equatable {
        case started
        case needsPermission(detail: String)
        case waitingForInput
        case finished
        case failed(String)
        case ended
    }

    struct Result: Equatable {
        /// `nil` when the session ended and should be removed.
        var session: AgentSession?
        var transitions: [Transition]
    }

    static func reduce(_ existing: AgentSession?, _ event: AgentEvent) -> Result {
        if case .sessionEnded = event.kind {
            return Result(session: nil, transitions: existing == nil ? [] : [.ended])
        }

        var s = existing ?? AgentSession(provider: event.provider, sessionID: event.sessionID,
                                         startedAt: event.receivedAt, lastUpdate: event.receivedAt)
        var transitions: [Transition] = existing == nil ? [.started] : []
        let previous = s.state

        s.lastUpdate = event.receivedAt
        s.isStale = false
        if let cwd = event.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let model = event.model, !model.isEmpty { s.model = model }
        if let path = event.transcriptPath { s.transcriptPath = path }
        s.terminal = s.terminal.merged(with: event.terminal)

        switch event.kind {
        case .sessionStarted:
            s.state = .starting
            s.subagentCount = 0
            s.currentTool = nil
        case .promptSubmitted(let prompt):
            s.state = .thinking
            if let prompt { s.lastPrompt = prompt }
        case .thinking:
            // A model request or finished tool while waiting for permission means the user
            // answered in the terminal; otherwise the agent is simply working.
            s.state = .thinking
            s.currentTool = nil
        case .toolStarted(let name, _):
            s.state = .runningTool(name)
            s.currentTool = name
            s.lastTool = name
        case .toolFinished:
            s.state = .thinking
            s.currentTool = nil
        case .toolFailed:
            s.state = .thinking
            s.currentTool = nil
        case .permissionRequested(let tool, let detail):
            let text = detail.map { "\(tool): \($0)" } ?? tool
            s.state = .waitingForPermission(text)
            s.lastTool = tool
        case .permissionNotice(let message):
            if !s.state.needsUser { s.state = .waitingForPermission(message ?? "Permission needed") }
        case .waitingForInput(let message):
            // Claude's idle_prompt arrives ~60 s after Stop. Only move to "waiting" if nothing
            // else happened since (a new prompt would have moved us to thinking).
            if case .done = s.state { s.state = .waitingForInput }
            else if !s.state.isWorking, !s.state.needsUser { s.state = .waitingForInput }
            if let message, s.lastAssistantMessage == nil { s.lastAssistantMessage = message }
        case .stopped(let lastMessage):
            s.state = .done
            s.currentTool = nil
            if let lastMessage, !lastMessage.isEmpty { s.lastAssistantMessage = lastMessage }
        case .failed(let error):
            s.state = .failed(error)
            s.currentTool = nil
        case .interrupted:
            s.state = .interrupted
            s.currentTool = nil
        case .subagentStarted:
            s.subagentCount += 1
        case .subagentStopped:
            s.subagentCount = max(0, s.subagentCount - 1)
        case .modelRequestFinished(let tokens, let error):
            if let tokens { s.tokenUsage = s.tokenUsage + tokens }
            if let error, !error.isEmpty { s.state = .failed(error) }
        case .sessionEnded:
            break
        case .other:
            break
        }

        if s.state != previous {
            switch s.state {
            case .waitingForPermission(let detail): transitions.append(.needsPermission(detail: detail))
            case .waitingForInput: transitions.append(.waitingForInput)
            case .done: transitions.append(.finished)
            case .failed(let error): transitions.append(.failed(error))
            default: break
            }
        }
        return Result(session: s, transitions: transitions)
    }
}
