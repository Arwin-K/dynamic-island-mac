import Foundation

/// Where an agent session runs, as reported by the hook script (from the hook's environment).
/// Used to bring the right terminal tab or app to the front.
struct AgentTerminalInfo: Equatable, Sendable {
    /// `$TERM_PROGRAM`: "Apple_Terminal", "iTerm.app", "ghostty", "WarpTerminal", "vscode"…
    var termProgram: String?
    /// `$TERM_SESSION_ID` (Terminal.app, others).
    var termSessionID: String?
    /// `$ITERM_SESSION_ID` ("w0t1p0:UUID").
    var itermSessionID: String?
    /// The controlling terminal, e.g. "ttys004".
    var tty: String?
    /// The hook's parent process and its parent (one of them is the agent).
    var parentPID: Int32?
    var grandparentPID: Int32?
    /// `$__CFBundleIdentifier`: the app that launched the shell (VS Code vs Cursor, Codex app…).
    var bundleID: String?

    init(termProgram: String? = nil, termSessionID: String? = nil, itermSessionID: String? = nil, tty: String? = nil,
         parentPID: Int32? = nil, grandparentPID: Int32? = nil, bundleID: String? = nil) {
        self.termProgram = termProgram; self.termSessionID = termSessionID; self.itermSessionID = itermSessionID
        self.tty = tty; self.parentPID = parentPID; self.grandparentPID = grandparentPID; self.bundleID = bundleID
    }

    /// Reads the `X-DI4M-*` headers the hook script sends.
    init(headers: [String: String]) {
        func h(_ name: String) -> String? {
            let v = headers[name.lowercased()]?.trimmingCharacters(in: .whitespaces)
            return (v?.isEmpty ?? true) ? nil : v
        }
        self.init(
            termProgram: h("X-DI4M-Term-Program"),
            termSessionID: h("X-DI4M-Term-Session"),
            itermSessionID: h("X-DI4M-ITerm-Session"),
            tty: h("X-DI4M-TTY").flatMap { $0 == "??" || $0 == "-" ? nil : $0 },
            parentPID: h("X-DI4M-PPID").flatMap(Int32.init),
            grandparentPID: h("X-DI4M-GPPID").flatMap(Int32.init),
            bundleID: h("X-DI4M-Bundle")
        )
    }

    /// Keeps known values when a later event lacks them.
    func merged(with newer: AgentTerminalInfo) -> AgentTerminalInfo {
        AgentTerminalInfo(
            termProgram: newer.termProgram ?? termProgram, termSessionID: newer.termSessionID ?? termSessionID,
            itermSessionID: newer.itermSessionID ?? itermSessionID, tty: newer.tty ?? tty,
            parentPID: newer.parentPID ?? parentPID, grandparentPID: newer.grandparentPID ?? grandparentPID,
            bundleID: newer.bundleID ?? bundleID
        )
    }
}

struct TokenUsage: Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var total: Int { input + output }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output)
    }
}

/// One lifecycle event from any agent, in a provider-neutral form. Each `AgentProvider`
/// maps its own hook JSON onto this; nothing after `normalize` knows which tool sent it.
struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStarted(source: String?)
        case promptSubmitted(prompt: String?)
        /// The model is working (after a tool, or before a model request).
        case thinking
        case toolStarted(name: String, detail: String?)
        case toolFinished(name: String)
        case toolFailed(name: String, error: String?)
        case permissionRequested(tool: String, detail: String?)
        /// A reminder that a permission prompt is showing (Claude's `permission_prompt`
        /// notification, ~6 s after PermissionRequest). Only matters if we missed the request.
        case permissionNotice(message: String?)
        /// The agent is idle and waiting for the user's next prompt (Claude's idle_prompt).
        case waitingForInput(message: String?)
        /// The turn finished.
        case stopped(lastMessage: String?)
        case failed(error: String)
        case interrupted
        case subagentStarted(id: String?)
        case subagentStopped(id: String?)
        case modelRequestFinished(tokens: TokenUsage?, error: String?)
        case sessionEnded(reason: String?)
        /// Anything else (compaction, config changes, events added after this was written).
        case other(name: String)
    }

    var provider: String
    var sessionID: String
    var kind: Kind
    var cwd: String?
    var model: String?
    var transcriptPath: String?
    /// Set when the event came from inside a subagent.
    var agentID: String?
    var terminal = AgentTerminalInfo()
    var receivedAt = Date()
}

/// The common state every session is in, whatever tool runs it.
enum AgentState: Equatable, Sendable {
    case starting
    case thinking
    case runningTool(String)
    case waitingForPermission(String)
    case waitingForInput
    case done
    case failed(String)
    case interrupted

    var needsUser: Bool {
        switch self {
        case .waitingForPermission, .waitingForInput: true
        default: false
        }
    }

    var isWorking: Bool {
        switch self {
        case .starting, .thinking, .runningTool: true
        default: false
        }
    }

    /// Lower sorts first: sessions that need the user, then failures, then working, then idle.
    var urgency: Int {
        switch self {
        case .waitingForPermission: 0
        case .waitingForInput: 1
        case .failed: 2
        case .runningTool, .thinking, .starting: 3
        case .done: 4
        case .interrupted: 5
        }
    }

    var label: String {
        switch self {
        case .starting: "Starting"
        case .thinking: "Thinking"
        case .runningTool(let tool): "Running \(tool)"
        case .waitingForPermission: "Needs permission"
        case .waitingForInput: "Waiting for you"
        case .done: "Done"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }
}

struct AgentSession: Identifiable, Equatable, Sendable {
    var provider: String
    var sessionID: String
    var id: String { Self.key(provider: provider, sessionID: sessionID) }

    var cwd: String?
    var gitBranch: String?
    var model: String?
    var state: AgentState = .starting
    var currentTool: String?
    var lastTool: String?
    var subagentCount = 0
    var startedAt: Date
    var lastUpdate: Date
    var lastAssistantMessage: String?
    var lastPrompt: String?
    var tokenUsage = TokenUsage()
    var terminal = AgentTerminalInfo()
    var transcriptPath: String?
    /// No event for longer than the stale timeout: the process may have died.
    var isStale = false

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Unknown project" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func key(provider: String, sessionID: String) -> String { "\(provider):\(sessionID)" }
}
