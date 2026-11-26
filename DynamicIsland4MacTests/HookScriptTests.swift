import Foundation
import Testing
@testable import DynamicIsland4Mac

/// Runs the real `agent-hook.sh` with a fake HOME and checks its safety contract.
struct HookScriptTests {
    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
        var seconds: Double
    }

    let scriptPath = Bundle.main.path(forResource: "agent-hook", ofType: "sh")!

    func makeHome(port: UInt16?, token: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("di4m-home-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("Library/Application Support/DynamicIsland4Mac")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let port { try String(port).write(to: dir.appendingPathComponent("port"), atomically: true, encoding: .utf8) }
        if let token { try "Authorization: Bearer \(token)\n".write(to: dir.appendingPathComponent("auth-header"), atomically: true, encoding: .utf8) }
        return home
    }

    func run(home: URL, args: [String], stdin: String) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["TERM_PROGRAM"] = "iTerm.app"
        env["ITERM_SESSION_ID"] = "w0t1p0:TEST"
        process.environment = env
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        // Reading to EOF also proves no background child kept our stdout open.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                   stderr: String(decoding: err, as: UTF8.self), seconds: Date().timeIntervalSince(start))
    }

    @Test func appNotInstalledExitsZeroSilentlyAndFast() throws {
        let home = try makeHome(port: nil, token: nil)
        let r = try run(home: home, args: ["claude-code"], stdin: #"{"session_id":"s","hook_event_name":"Stop"}"#)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.isEmpty)
        #expect(r.seconds < 1)
    }

    @Test func appNotRunningExitsZeroSilentlyAndFast() throws {
        let home = try makeHome(port: 1, token: "x")
        for args in [["codex"], ["codex", "permission", "2"]] {
            let r = try run(home: home, args: args, stdin: #"{"session_id":"s","hook_event_name":"PermissionRequest"}"#)
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
            #expect(r.seconds < 2)
        }
    }

    @Test func forwardsEventsWithMetadata() async throws {
        let server = try await TestServer()
        let home = try makeHome(port: server.port, token: server.token)
        let body = #"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}"#
        let r = try run(home: home, args: ["claude-code"], stdin: body)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.seconds < 1)
        await server.waitForRequests(1)
        let request = try #require(server.requests.first)
        #expect(request.path == "/events")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
        #expect(request.headers["x-di4m-provider"] == "claude-code")
        #expect(request.headers["x-di4m-term-program"] == "iTerm.app")
        #expect(request.headers["x-di4m-iterm-session"] == "w0t1p0:TEST")
    }

    @Test func permissionPrintsOnlyAnExplicitDecision() async throws {
        let decision = #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"no"},"hookEventName":"PermissionRequest"}}"#
        let decides = try await TestServer { _ in LocalServer.Response(status: 200, body: Data(decision.utf8)) }
        let home = try makeHome(port: decides.port, token: decides.token)
        let r = try run(home: home, args: ["codex", "permission", "5"], stdin: "{}")
        #expect(r.status == 0)
        #expect(r.stdout.trimmingCharacters(in: .newlines) == decision)

        let undecided = try await TestServer { _ in .noContent }
        let home2 = try makeHome(port: undecided.port, token: undecided.token)
        let r2 = try run(home: home2, args: ["claude-code", "permission", "5"], stdin: "{}")
        #expect(r2.status == 0)
        #expect(r2.stdout.isEmpty)
    }

    @Test func permissionTimesOutToNoDecision() async throws {
        let slow = try await TestServer { _ in Thread.sleep(forTimeInterval: 4); return LocalServer.Response(status: 200, body: Data("{}".utf8)) }
        let home = try makeHome(port: slow.port, token: slow.token)
        let r = try run(home: home, args: ["claude-code", "permission", "1"], stdin: "{}")
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.seconds < 3)
    }
}
