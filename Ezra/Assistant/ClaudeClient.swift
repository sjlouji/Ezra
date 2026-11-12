import Foundation

enum ClaudeError: LocalizedError, Equatable {
    case noKey
    case server(status: Int, message: String)
    case unreadableResponse
    case refused(String)
    case tooManySteps

    var errorDescription: String? {
        switch self {
        case .noKey:
            "Add your Claude API key in Settings to use Claude."
        case .server(401, _):
            "Claude did not accept the API key. Check it in Settings."
        case .server(429, _):
            "Claude's rate limit was reached. Wait a moment and try again."
        case .server(529, _):
            "Claude is overloaded right now. Try again shortly."
        case .server(let status, let message):
            "Claude answered \(status): \(message)"
        case .unreadableResponse:
            "Claude sent a response that could not be read."
        case .refused(let why):
            "Claude declined to answer this." + (why.isEmpty ? "" : " \(why)")
        case .tooManySteps:
            "\(Brand.assistant) stopped after too many steps without finishing. Try a narrower request."
        }
    }
}

/// One answer from the Messages API.
struct ClaudeReply: Sendable {
    let content: [JSONValue]
    let stopReason: String
    /// Why the model declined, when `stopReason` is "refusal".
    let refusal: String
}

/// The Claude Messages API over plain HTTPS. There is no official Swift SDK.
struct ClaudeClient: Sendable {
    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let key: String
    var transport: LineTransport = HTTP.liveLines

    /// Sends the conversation and reads the reply as it is written. `onText` is given the answer's text so far, each time it grows.
    func send(
        system: String, tools: [JSONValue], messages: [JSONValue], params: ChatParams = ChatParams(),
        onText: @MainActor @Sendable (String) -> Void = { _ in },
        onTool: @MainActor @Sendable (_ name: String, _ characters: Int) -> Void = { _, _ in }
    ) async throws -> ClaudeReply {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // A turn with web searches and thinking can take minutes.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines the request, the API retries it on a fallback model in the same call.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        var body: [String: JSONValue] = [:]
        if let effort = params.effort { body["output_config"] = .object(["effort": .string(effort)]) }
        // Reasoning is not sent back by default; asking for its summary is what makes it showable.
        if params.thinks { body["thinking"] = .object(["type": .string("adaptive"), "display": .string("summarized")]) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body.merging([
            "model": .string(Self.model),
            "max_tokens": .number(64000),
            "stream": .bool(true),
            "fallbacks": .string("default"),
            "system": .string(system),
            "tools": .array(tools),
            "messages": .array(messages),
        ]) { _, fixed in fixed }))

        let (lines, response) = try await transport(request)
        var stream = ClaudeStream()
        // An error, or a server that does not stream, answers with one JSON document instead of events.
        var plain = ""
        for try await line in lines {
            if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONValue.parse(payload) else { throw ClaudeError.unreadableResponse }
                let before = stream.text
                try stream.take(event)
                if stream.text != before { await onText(stream.text) }
                if let call = stream.preparing { await onTool(call.tool, call.characters) }
            } else if !line.hasPrefix("event:") && !line.hasPrefix(":") {
                plain += line
            }
        }
        if !plain.trimmed.isEmpty || !(200..<300).contains(response.statusCode) {
            guard let body = try? JSONValue.parse(plain) else {
                // An error page may not be JSON; the status is reported either way.
                guard (200..<300).contains(response.statusCode) else {
                    throw ClaudeError.server(status: response.statusCode, message: "no details")
                }
                throw ClaudeError.unreadableResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ClaudeError.server(status: response.statusCode, message: body["error"]?["message"]?.text ?? "no details")
            }
            guard case .array(let content) = body["content"], let stopReason = body["stop_reason"]?.text else {
                throw ClaudeError.unreadableResponse
            }
            let text = content.filter { $0["type"]?.text == "text" }.compactMap { $0["text"]?.text }.joined()
            if !text.isEmpty { await onText(text) }
            return ClaudeReply(content: content, stopReason: stopReason, refusal: body["stop_details"]?["explanation"]?.text ?? "")
        }
        guard let stopReason = stream.stopReason else { throw ClaudeError.unreadableResponse }
        return ClaudeReply(content: stream.content, stopReason: stopReason, refusal: stream.refusal)
    }
}
