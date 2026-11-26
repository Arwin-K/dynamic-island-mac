import Foundation
import Testing
@testable import DynamicIsland4Mac

struct LocalServerParseTests {
    @Test func parsesCompleteRequest() {
        let raw = "POST /events?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = LocalServer.parse(Data(raw.utf8)) else { Issue.record("not complete"); return }
        #expect(request.method == "POST")
        #expect(request.path == "/events")
        #expect(request.headers["authorization"] == "Bearer abc")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForBody() {
        let raw = "POST /events HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        guard case .incomplete = LocalServer.parse(Data(raw.utf8)) else { Issue.record("expected incomplete"); return }
    }

    @Test func rejectsHugeBodies() {
        let raw = "POST /events HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        guard case .tooLarge = LocalServer.parse(Data(raw.utf8)) else { Issue.record("expected tooLarge"); return }
    }

    @Test func constantTimeCompare() {
        #expect(LocalServer.constantTimeEquals("abc", "abc"))
        #expect(!LocalServer.constantTimeEquals("abc", "abd"))
        #expect(!LocalServer.constantTimeEquals("abc", "abcd"))
    }
}

/// Starts a real server on a random loopback port.
final class TestServer: @unchecked Sendable {
    let server: LocalServer
    let port: UInt16
    let token = "test-token-0123456789abcdef0123456789abcdef"
    private let lock = NSLock()
    private var _requests: [LocalServer.Request] = []
    var requests: [LocalServer.Request] { lock.withLock { _requests } }

    init(response: @escaping @Sendable (LocalServer.Request) -> LocalServer.Response = { _ in .ok }) async throws {
        port = UInt16.random(in: 49_200...60_000)
        var box: TestServer?
        server = LocalServer(port: port, token: token) { request, respond in
            box?.lock.withLock { box?._requests.append(request) }
            respond(response(request))
        }
        box = self
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

    func waitForRequests(_ count: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while requests.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    deinit { server.stop() }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

struct LocalServerLiveTests {
    func request(_ port: UInt16, path: String, token: String?) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @Test func requiresTheToken() async throws {
        let server = try await TestServer()
        #expect(try await request(server.port, path: "/events", token: nil) == 401)
        #expect(try await request(server.port, path: "/events", token: "wrong") == 401)
        #expect(try await request(server.port, path: "/events", token: server.token) == 200)
        #expect(server.requests.count == 1)
    }
}
