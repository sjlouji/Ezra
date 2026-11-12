import Foundation
import Network
import SwiftData

/// The door Claude's requests come through: a listener on this Mac only (127.0.0.1), off until the user switches it on.
/// Every request must carry the token Ezra made, and a request from a web page (one with an Origin) is refused, so a
/// site open in a browser cannot reach the user's to-dos.
@MainActor
@Observable
final class MCPServer {
    enum Status: Equatable {
        case off
        case starting
        case listening(Int)
        case failed(String)
    }

    static let shared = MCPServer()
    static let enabledKey = "mcp.enabled", defaultPort = 47821

    private(set) var status = Status.off
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var container: ModelContainer?

    /// Starts or stops to match the user's setting. Called at launch and when the setting changes.
    func apply(container: ModelContainer? = EzraStore.shared) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), let container else { return stop() }
        do {
            start(container: container, port: Self.defaultPort, token: try Self.storedToken())
        } catch {
            Log.assistant.error("The Claude connection has no token: \(String(describing: error), privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    func start(container: ModelContainer, port: Int, token: String) {
        stop()
        (self.container, self.token, status) = (container, token, .starting)
        do {
            guard let endpoint = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw URLError(.badURL) }
            let parameters = NWParameters.tcp
            // This Mac only: nothing on the network can connect.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpoint)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { // the listener reports on the main queue
                    switch state {
                    case .ready: self?.status = .listening(port)
                    case .failed(let error):
                        Log.assistant.error("The Claude connection stopped: \(String(describing: error), privacy: .public)")
                        self?.status = .failed("Port \(port) could not be used: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    connection.start(queue: .main)
                    self?.receive(on: connection, so: Data())
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.assistant.error("The Claude connection could not start: \(String(describing: error), privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        (listener, status) = (nil, .off)
    }

    /// Reads until a whole request has arrived, answers it and hangs up.
    private func receive(on connection: NWConnection, so far: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                let buffer = far + (data ?? Data())
                if let request = HTTPRequest(buffer) {
                    let reply = self?.reply(to: request) ?? HTTPReply(status: "503 Service Unavailable")
                    connection.send(content: reply.data, completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil || buffer.count > 4 << 20 {
                    connection.cancel()
                } else {
                    self?.receive(on: connection, so: buffer)
                }
            }
        }
    }

    func reply(to request: HTTPRequest) -> HTTPReply {
        // A browser adds Origin to what a page sends; Claude does not. No page gets in, with or without the token.
        guard request.headers["origin"] == nil else { return HTTPReply(status: "403 Forbidden") }
        guard request.path == "/mcp" else { return HTTPReply(status: "404 Not Found") }
        guard request.method == "POST" else { return HTTPReply(status: "405 Method Not Allowed") }
        guard !token.isEmpty, request.headers["authorization"] == "Bearer \(token)" else { return HTTPReply(status: "401 Unauthorized") }
        guard let container else { return HTTPReply(status: "503 Service Unavailable") }
        guard let answer = MCPService.respond(to: request.body, container: container) else { return HTTPReply(status: "202 Accepted") }
        return HTTPReply(status: "200 OK", body: answer)
    }

    // MARK: The token

    /// The token Claude must send, made the first time it is needed and kept in the Keychain.
    static func storedToken() throws -> String {
        if let kept = try Keychain.read(Keychain.mcpToken).flatMap({ String(data: $0, encoding: .utf8) }), !kept.isEmpty { return kept }
        return try newToken()
    }

    /// Replaces the token; whatever was set up with the old one stops working.
    @discardableResult
    static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try Keychain.write(Data(token.utf8), Keychain.mcpToken)
        return token
    }
}

/// As much of HTTP as one local request needs.
struct HTTPRequest {
    let method: String
    let path: String
    /// Header names in lower case.
    let headers: [String: String]
    let body: Data

    /// Nil until the head and the whole body have arrived.
    init?(_ data: Data) {
        guard let gap = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[..<gap.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let rest = data[gap.upperBound...]
        guard rest.count >= length else { return nil }
        (method, path, self.headers, body) = (String(first[0]), String(first[1]), headers, Data(rest.prefix(length)))
    }
}

struct HTTPReply {
    let status: String
    var body = Data()

    var data: Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
}
