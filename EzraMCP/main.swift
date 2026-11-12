import Foundation

// ezra-mcp: what Claude starts to talk to Ezra. It passes each request Claude writes on standard input to the Ezra
// app on this Mac and writes Ezra's reply on standard output. Ezra is opened when it is not running.
// The token (EZRA_MCP_TOKEN) comes from Ezra's Settings; the port (EZRA_MCP_PORT) only when it was changed there.

let token = ProcessInfo.processInfo.environment["EZRA_MCP_TOKEN"] ?? ""
let port = UInt16(ProcessInfo.processInfo.environment["EZRA_MCP_PORT"] ?? "") ?? 47821

enum Failure: Error {
    case unreachable
    case refused(Int)
}

/// Sends one request to Ezra and returns the reply's status and body.
func post(_ body: Data) throws -> (status: Int, body: Data) {
    let handle = socket(AF_INET, SOCK_STREAM, 0)
    guard handle >= 0 else { throw Failure.unreachable }
    defer { close(handle) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw Failure.unreachable }

    let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var request = Data(head.utf8) + body
    while !request.isEmpty {
        let sent = request.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        guard sent > 0 else { throw Failure.unreachable }
        request.removeFirst(sent)
    }
    // Ezra hangs up when it has answered, so the reply is everything until then.
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(handle, &chunk, chunk.count)
        if count <= 0 { break }
        reply.append(contentsOf: chunk[..<count])
    }
    guard let gap = reply.range(of: Data("\r\n\r\n".utf8)), let first = String(data: reply[..<gap.lowerBound], encoding: .utf8)?.split(separator: " "),
          first.count >= 2, let status = Int(first[1])
    else { throw Failure.unreachable }
    return (status, Data(reply[gap.upperBound...]))
}

/// Opens Ezra without bringing it to the front, and waits for it to start listening.
func wakeEzra() -> Bool {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", "app.ezra.Ezra"]
    do { try open.run() } catch { return false }
    open.waitUntilExit()
    for _ in 0..<40 {
        usleep(250_000)
        if (try? post(Data(#"{"jsonrpc":"2.0","method":"notifications/ping"}"#.utf8))) != nil { return true }
    }
    return false
}

func write(_ line: Data) {
    FileHandle.standardOutput.write(line + Data("\n".utf8))
}

/// Tells Claude a request failed, in the protocol's own terms. A notification (no id) is owed no answer.
func fail(_ request: Data, _ message: String) {
    FileHandle.standardError.write(Data("ezra-mcp: \(message)\n".utf8))
    guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any], let id = object["id"], !(id is NSNull) else { return }
    let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
    if let line = try? JSONSerialization.data(withJSONObject: error) { write(line) }
}

while let line = readLine(strippingNewline: true) {
    let request = Data(line.utf8)
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    do {
        let reply: (status: Int, body: Data)
        do {
            reply = try post(request)
        } catch Failure.unreachable {
            guard wakeEzra() else {
                fail(request, "Ezra is not answering. Open Ezra and switch on Settings › Claude › Let Claude use Ezra.")
                continue
            }
            reply = try post(request)
        }
        switch reply.status {
        case 200: write(reply.body)
        case 202: break
        case 401: fail(request, "Ezra did not accept the token. Copy the setup again from Ezra › Settings › Claude.")
        default: fail(request, "Ezra answered with status \(reply.status).")
        }
    } catch {
        fail(request, "Ezra is not answering. Open Ezra and switch on Settings › Claude › Let Claude use Ezra.")
    }
}
