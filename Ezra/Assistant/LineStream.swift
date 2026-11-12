import Foundation

/// A request whose answer is read line by line as it arrives, so a reply can be shown while it is still being written.
typealias LineTransport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)

extension HTTP {
    static let liveLines: LineTransport = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.unreadableResponse }
        return (AsyncThrowingStream { continuation in
            let reading = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }, http)
    }
}

extension JSONValue {
    /// This object with one field set; anything that is not an object becomes one.
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        var fields: [String: JSONValue] = if case .object(let existing) = self { existing } else { [:] }
        fields[key] = value
        return .object(fields)
    }
}

/// Puts a streamed Claude reply back together. The API sends each content block in pieces; what comes out is the
/// same `content` array a non-streamed reply carries, which must be sent back unchanged on the next request.
struct ClaudeStream {
    private(set) var blocks: [Int: JSONValue] = [:]
    /// Tool arguments arrive as fragments of JSON text, per block.
    private var partialInputs: [Int: String] = [:]
    private(set) var stopReason: String?
    private(set) var refusal = ""
    /// The answer's text so far.
    private(set) var text = ""
    /// The tool call being written right now, and how much of its arguments has arrived; nil between calls.
    private(set) var preparing: (tool: String, characters: Int)?

    var content: [JSONValue] { blocks.keys.sorted().compactMap { blocks[$0] } }

    /// Takes one `data:` payload of the event stream.
    mutating func take(_ event: JSONValue) throws {
        let index = if case .number(let number) = event["index"] { Int(number) } else { 0 }
        switch event["type"]?.text {
        case "content_block_start":
            blocks[index] = event["content_block"] ?? .object([:])
            if let name = blocks[index]?["name"]?.text, blocks[index]?["type"]?.text == "tool_use" { preparing = (name, 0) }
        case "content_block_delta":
            guard let delta = event["delta"], let block = blocks[index] else { throw ClaudeError.unreadableResponse }
            switch delta["type"]?.text {
            case "text_delta":
                let piece = delta["text"]?.text ?? ""
                text += piece
                blocks[index] = block.setting("text", .string((block["text"]?.text ?? "") + piece))
            case "input_json_delta":
                partialInputs[index, default: ""] += delta["partial_json"]?.text ?? ""
                if let tool = preparing?.tool { preparing = (tool, partialInputs[index]?.count ?? 0) }
            case "thinking_delta":
                blocks[index] = block.setting("thinking", .string((block["thinking"]?.text ?? "") + (delta["thinking"]?.text ?? "")))
            case "signature_delta":
                blocks[index] = block.setting("signature", delta["signature"] ?? .null)
            case "citations_delta":
                blocks[index] = block.setting("citations", .array((block["citations"]?.items ?? []) + [delta["citation"] ?? .null]))
            default:
                break // a kind of delta added after this was written; the block keeps what it has
            }
        case "content_block_stop":
            preparing = nil
            if let json = partialInputs.removeValue(forKey: index), !json.isEmpty, let block = blocks[index] {
                blocks[index] = block.setting("input", try JSONValue.parse(json))
            }
        case "message_delta":
            stopReason = event["delta"]?["stop_reason"]?.text ?? stopReason
            refusal = event["delta"]?["stop_details"]?["explanation"]?.text ?? refusal
        case "error":
            throw ClaudeError.server(status: 200, message: event["error"]?["message"]?.text ?? "the stream failed")
        default:
            break // message_start, message_stop, ping
        }
    }
}
