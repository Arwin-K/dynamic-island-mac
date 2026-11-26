import Foundation
import Testing
@testable import DynamicIsland4Mac

/// Collects the single response an approval produces.
final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [LocalServer.Response] = []
    var responses: [LocalServer.Response] { lock.withLock { _responses } }
    func record(_ r: LocalServer.Response) { lock.withLock { _responses.append(r) } }
}

@MainActor
struct ApprovalCenterTests {
    let raw: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/proj", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]

    @Test func allowReturnsTheProvidersExactJSON() throws {
        let center = ApprovalCenter()
        let box = ResponseBox()
        let provider = CodexProvider()
        center.enqueue(providerID: "codex", raw: raw, timeout: 30, respond: box.record)
        let request = try #require(center.pending.first)
        #expect(request.toolName == "Bash")
        #expect(request.input.contains("rm -rf build"))
        #expect(request.projectName == "proj")
        center.decide(request.id, .allow, provider: provider)
        #expect(box.responses.count == 1)
        #expect(box.responses.first?.status == 200)
        #expect(box.responses.first?.body == provider.permissionResponse(.allow))
        #expect(center.pending.isEmpty)
    }

    @Test func denyCarriesTheMessage() throws {
        let center = ApprovalCenter()
        let box = ResponseBox()
        let provider = ClaudeCodeProvider()
        center.enqueue(providerID: "claude-code", raw: raw, timeout: 30, respond: box.record)
        center.decide(try #require(center.pending.first).id, .deny(message: "nope"), provider: provider)
        let body = try #require(box.responses.first?.body)
        let decision = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "nope")
    }

    @Test func timeoutIsNoDecision() async throws {
        let center = ApprovalCenter()
        let box = ResponseBox()
        center.enqueue(providerID: "codex", raw: raw, timeout: 0.2, respond: box.record)
        try await Task.sleep(for: .milliseconds(600))
        #expect(box.responses.map(\.status) == [204])
        #expect(center.pending.isEmpty)
    }

    @Test func answeredElsewhereIsNoDecision() {
        let center = ApprovalCenter()
        let box = ResponseBox()
        center.enqueue(providerID: "codex", raw: raw, timeout: 30, respond: box.record)
        center.cancelAll(sessionKey: "codex:other", reason: "test")
        #expect(box.responses.isEmpty)
        center.cancelAll(sessionKey: "codex:s1", reason: "test")
        #expect(box.responses.map(\.status) == [204])
    }

    @Test func onlyOneResponseEver() throws {
        let center = ApprovalCenter()
        let box = ResponseBox()
        let provider = CodexProvider()
        center.enqueue(providerID: "codex", raw: raw, timeout: 30, respond: box.record)
        let id = try #require(center.pending.first).id
        center.decide(id, .allow, provider: provider)
        center.decide(id, .deny(message: "late"), provider: provider)
        center.cancel(id, reason: "late")
        #expect(box.responses.count == 1)
    }

    /// The real hook script, a real server, and a decision made in the island.
    @Test func endToEndThroughTheHookScript() async throws {
        let center = ApprovalCenter()
        let provider = ClaudeCodeProvider()
        let server = try await TestServerWithHandler { request, respond in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let raw = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
                    center.enqueue(providerID: "claude-code", raw: raw, timeout: 10, respond: respond)
                }
            }
        }
        let home = try HookScriptTests().makeHome(port: server.port, token: server.token)
        let script = HookScriptTests()
        let run = Task.detached {
            try script.run(home: home, args: ["claude-code", "permission", "10"],
                           stdin: #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        }
        // Wait for the request to reach the island, then click Allow.
        let deadline = Date().addingTimeInterval(5)
        while center.pending.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let request = try #require(center.pending.first)
        #expect(request.input.contains("\"command\" : \"ls\""))
        center.decide(request.id, .allow, provider: provider)
        let result = try await run.value
        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .newlines) == String(decoding: provider.permissionResponse(.allow), as: UTF8.self))
    }
}

/// Like `TestServer`, but with an asynchronous handler (for long-polled responses).
final class TestServerWithHandler: @unchecked Sendable {
    let server: LocalServer
    let port = UInt16.random(in: 49_200...60_000)
    let token = "approval-test-token-0123456789abcdef0123456789"

    init(handler: @escaping LocalServer.Handler) async throws {
        server = LocalServer(port: port, token: token, handler: handler)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            server.start { result in
                guard once.claim() else { return }
                switch result {
                case .success: c.resume()
                case .failure(let e): c.resume(throwing: e)
                }
            }
        }
    }

    deinit { server.stop() }
}
