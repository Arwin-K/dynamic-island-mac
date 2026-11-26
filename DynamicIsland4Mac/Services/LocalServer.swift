import Foundation
import Network
import Security

/// A tiny HTTP/1.1 server for the agent hooks, built on Network.framework.
///
/// Security model:
/// * Bound to **127.0.0.1 only** (`requiredLocalEndpoint` + `acceptLocalOnly`), so nothing
///   off this Mac can connect.
/// * Every request must carry `Authorization: Bearer <token>`. The token is a random
///   256-bit value in `~/Library/Application Support/DynamicIsland4Mac/token` (mode 600), so
///   other local users can't read it and web pages can't guess it.
/// * Request size is capped; one request per connection; connections time out.
///
/// It handles a handful of requests a minute, so simplicity beats performance here.
final class LocalServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Lowercased header names.
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var body: Data = Data()
        var contentType = "application/json"

        static let ok = Response(status: 200, body: Data("{}".utf8))
        static let noContent = Response(status: 204)
        static let unauthorized = Response(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        static let notFound = Response(status: 404, body: Data(#"{"error":"not found"}"#.utf8))
        static let tooLarge = Response(status: 413, body: Data(#"{"error":"too large"}"#.utf8))
        static let badRequest = Response(status: 400, body: Data(#"{"error":"bad request"}"#.utf8))
    }

    /// Handlers call `respond` exactly once, from any thread (long-poll routes respond later).
    typealias Handler = @Sendable (Request, @escaping @Sendable (Response) -> Void) -> Void

    static let maxBodyBytes = 4 * 1024 * 1024
    private static let maxHeaderBytes = 32 * 1024

    let port: UInt16
    private let token: String
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "DynamicIsland4Mac.LocalServer")

    init(port: UInt16, token: String, handler: @escaping Handler) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    /// Starts listening. `onState` reports `.ready` or a failure (e.g. port in use).
    func start(onState: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ServerError.invalidPort }
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: onState(.success(()))
                case .failed(let error): onState(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    enum ServerError: LocalizedError {
        case invalidPort
        var errorDescription: String? { "Invalid port" }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Drop connections that never finish sending a request.
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
            if let connection, connection.state != .cancelled, connection.state != .setup {
                // Long-poll responses cancel the connection themselves; this only catches stalls
                // before a full request arrived (see `receivedFullRequest`).
                if connection.receivedFullRequest == false { connection.cancel() }
            }
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { connection.cancel(); return }

            switch Self.parse(buffer) {
            case .incomplete:
                if isComplete || buffer.count > Self.maxHeaderBytes + Self.maxBodyBytes {
                    self.send(.badRequest, on: connection)
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .tooLarge:
                self.send(.tooLarge, on: connection)
            case .invalid:
                self.send(.badRequest, on: connection)
            case .complete(let request):
                connection.receivedFullRequest = true
                guard self.isAuthorized(request) else {
                    self.send(.unauthorized, on: connection)
                    return
                }
                self.handler(request) { [weak self] response in
                    self?.queue.async { self?.send(response, on: connection) }
                }
            }
        }
    }

    private func isAuthorized(_ request: Request) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return Self.constantTimeEquals(String(header.dropFirst(7)), token)
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing (internal for tests)

    enum ParseResult {
        case incomplete, tooLarge, invalid
        case complete(Request)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        guard length <= maxBodyBytes else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return .complete(Request(method: String(requestLine[0]), path: path, headers: headers, body: Data(body)))
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}

private var receivedFullRequestKey: UInt8 = 0

private extension NWConnection {
    /// Whether a complete request arrived (so the stall timer leaves long-polls alone).
    var receivedFullRequest: Bool {
        get { (objc_getAssociatedObject(self, &receivedFullRequestKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &receivedFullRequestKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

/// The shared secret the hook script sends.
enum AgentToken {
    /// Reads the token, creating it (and the port file) on first launch.
    static func loadOrCreate() throws -> String {
        let url = AppPaths.tokenFile
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "DynamicIsland4Mac", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not generate a random token"])
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try writePrivate(token, to: url)
        return token
    }

    /// `Authorization` header for the hook script, read by `curl -H @file` so the token never
    /// appears in a process's arguments.
    static func writeAuthHeader(_ token: String) throws {
        try writePrivate("Authorization: Bearer \(token)\n", to: AppPaths.supportDirectory.appendingPathComponent("auth-header"))
    }

    /// The hook script reads the port from here, so changing it in Settings needs no reinstall.
    static func writePort(_ port: Int) throws {
        try writePrivate(String(port), to: AppPaths.portFile)
    }

    private static func writePrivate(_ string: String, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: Data(string.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "DynamicIsland4Mac", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.lastPathComponent)"])
        }
    }
}
