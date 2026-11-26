import Foundation
import Observation

/// Wires the agent pipeline together: token → local server → provider `normalize` → session
/// store. Also installs the hook script into Application Support.
@MainActor
@Observable
final class AgentHub {
    enum ServerState: Equatable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    let providers: [AgentProvider]
    let store = AgentSessionStore()
    let approvals = ApprovalCenter()
    private(set) var serverState: ServerState = .stopped
    /// When each provider last sent an event (persisted), for "receiving events" status.
    private(set) var lastEventAt: [String: Date] = [:]

    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored private var server: LocalServer?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingTests: [String: (Date, (TimeInterval?) -> Void)] = [:]

    init(services: AppServices, providers: [AgentProvider]? = nil) {
        self.services = services
        self.providers = providers ?? AgentProviders.makeAll()
        lastEventAt = services.preferences.values.agentLastEventAt.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func provider(id: String) -> AgentProvider? { providers.first { $0.id == id } }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        store.staleTimeoutMinutes = services.preferences.values.agentStaleTimeoutMinutes
        do {
            let token = try AgentToken.loadOrCreate()
            try AgentToken.writeAuthHeader(token)
            self.token = token
            try Self.installHookScript()
        } catch {
            serverState = .failed(error.localizedDescription)
            Log.server.error("Agent setup failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        startServer()
        observePreferences()
    }

    func stop() {
        approvals.cancelAll(reason: "app quitting")
        started = false
        server?.stop()
        server = nil
        serverState = .stopped
    }

    private func startServer() {
        guard let token else { return }
        server?.stop()
        let port = services.preferences.values.serverPort
        do { try AgentToken.writePort(port) } catch {
            serverState = .failed(error.localizedDescription)
            return
        }
        let server = LocalServer(port: UInt16(clamping: port), token: token) { [weak self] request, respond in
            DispatchQueue.main.async {
                guard let self else { respond(.notFound); return }
                self.route(request, respond: respond)
            }
        }
        server.start { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.serverState = .running(port: port)
                    Log.server.info("Listening on 127.0.0.1:\(port)")
                case .failure(let error):
                    self?.serverState = .failed("Port \(port): \(error.localizedDescription)")
                    Log.server.error("Server failed on port \(port): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        self.server = server
    }

    private func observePreferences() {
        withObservationTracking {
            _ = services.preferences.values.serverPort
            _ = services.preferences.values.agentStaleTimeoutMinutes
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.started else { return }
                self.store.staleTimeoutMinutes = self.services.preferences.values.agentStaleTimeoutMinutes
                if case .running(let port) = self.serverState, port == self.services.preferences.values.serverPort {} else {
                    self.startServer()
                }
                self.observePreferences()
            }
        }
    }

    /// Copies the bundled hook script to Application Support, only when it changed, so the
    /// path the installers write stays the same across app updates (Codex asks users to
    /// re-trust hooks whose definition changes).
    static func installHookScript() throws {
        guard let bundled = Bundle.main.url(forResource: "agent-hook", withExtension: "sh") else { return }
        let target = AppPaths.installedHookScript
        let new = try Data(contentsOf: bundled)
        if (try? Data(contentsOf: target)) != new {
            try new.write(to: target, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    }

    // MARK: - Requests

    private func route(_ request: LocalServer.Request, respond: @escaping @Sendable (LocalServer.Response) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(LocalServer.Response(status: 200, body: Data(#"{"ok":true,"app":"DynamicIsland4Mac"}"#.utf8)))
        case ("POST", "/events"):
            respond(.ok) // acknowledge first; the hook never waits on our processing
            handleEvent(request)
        case ("POST", "/permission"):
            handlePermission(request, respond: respond)
        default:
            respond(.notFound)
        }
    }

    private func handleEvent(_ request: LocalServer.Request) {
        guard let providerID = request.headers["x-di4m-provider"], let provider = provider(id: providerID) else {
            Log.agents.error("Event from unknown provider \(request.headers["x-di4m-provider"] ?? "nil", privacy: .public)")
            return
        }
        guard services.preferences.values.agentPreferences(for: providerID).enabled else { return }
        guard let raw = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            Log.agents.error("Unparseable event body from \(providerID, privacy: .public)")
            return
        }
        // "Send test event" from Settings: confirms script → token → server, without creating a session.
        if let sessionID = raw["session_id"] as? String, sessionID.hasPrefix(Self.testSessionPrefix) {
            if let (sentAt, completion) = pendingTests.removeValue(forKey: sessionID) {
                completion(Date().timeIntervalSince(sentAt))
            }
            return
        }
        markEventReceived(from: providerID)
        guard var event = provider.normalize(raw) else {
            Log.agents.debug("Ignored \(providerID, privacy: .public) event \(raw["hook_event_name"] as? String ?? "?", privacy: .public)")
            return
        }
        event.terminal = AgentTerminalInfo(headers: request.headers)
        // The tool ran, the turn ended, or a new prompt came in: any pending island prompt
        // for this session was answered in the terminal, so withdraw ours.
        switch event.kind {
        case .toolFinished, .toolFailed, .stopped, .interrupted, .promptSubmitted, .sessionEnded, .failed:
            approvals.cancelAll(sessionKey: AgentSession.key(provider: event.provider, sessionID: event.sessionID), reason: "answered elsewhere")
        default:
            break
        }
        if case .other(let name) = event.kind {
            Log.agents.debug("\(providerID, privacy: .public): untracked event \(name, privacy: .public)")
        }
        store.apply(event)
    }

    /// Island approvals (opt-in per provider). Anything but an explicit click answers 204 =
    /// "no decision", so the hook prints nothing and the agent shows its normal prompt.
    private func handlePermission(_ request: LocalServer.Request, respond: @escaping @Sendable (LocalServer.Response) -> Void) {
        guard let providerID = request.headers["x-di4m-provider"], provider(id: providerID) != nil else {
            respond(.noContent)
            return
        }
        let prefs = services.preferences.values.agentPreferences(for: providerID)
        guard prefs.enabled, prefs.approvalsEnabled,
              let raw = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            respond(.noContent)
            return
        }
        // Answer a little before the hook script's own curl timeout, so it receives our
        // "no decision" instead of timing out.
        let timeout = max(5, prefs.approvalTimeoutSeconds - 2)
        approvals.enqueue(providerID: providerID, raw: raw, timeout: timeout, respond: respond)
    }

    static let testSessionPrefix = "di4m-test-"

    /// Runs the installed hook script exactly as an agent would, with a synthetic event, and
    /// reports the round-trip time (nil if it never arrived within 5 s).
    func sendTestEvent(providerID: String, completion: @escaping (TimeInterval?) -> Void) {
        let sessionID = Self.testSessionPrefix + UUID().uuidString
        pendingTests[sessionID] = (Date(), completion)
        let payload = #"{"session_id":"\#(sessionID)","hook_event_name":"DynamicIsland4MacTest","cwd":"\#(NSHomeDirectory())"}"#
        let script = AppPaths.installedHookScript.path
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script, providerID]
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if let (_, completion) = self?.pendingTests.removeValue(forKey: sessionID) { completion(nil) }
        }
    }

    private func markEventReceived(from providerID: String) {
        let now = Date()
        // Persist at most once a minute.
        let previous = lastEventAt[providerID]
        lastEventAt[providerID] = now
        if previous.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            services.preferences.update { $0.agentLastEventAt[providerID] = now.timeIntervalSince1970 }
        }
    }
}
