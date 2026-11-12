import Foundation

enum OllamaError: LocalizedError, Equatable {
    case notRunning
    case noModelsInstalled
    case noModel
    case server(status: Int, message: String)
    case unreadableResponse
    case tooLong(characters: Int)
    case tooManySteps

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Ollama is not running on this Mac. Open the Ollama app, then try again."
        case .noModelsInstalled:
            "Ollama has no chat models installed. Add one in Terminal, for example: ollama pull qwen3:14b"
        case .noModel:
            "Choose an Ollama model in Settings to use Ollama."
        case .server(let status, let message):
            "Ollama answered \(status): \(message)"
        case .unreadableResponse:
            "Ollama sent a response that could not be read."
        case .tooLong(let characters):
            "This conversation is too long for the Ollama model (\(characters.formatted()) characters; about \(OllamaAgent.characterLimit.formatted()) fit). Start a new chat, attach a shorter file, or switch to Claude."
        case .tooManySteps:
            "\(Brand.assistant) stopped after too many steps without finishing. Try a narrower request."
        }
    }
}

/// Ollama's local API on this Mac.
struct OllamaClient: Sendable {
    private static let base = URL(string: "http://localhost:11434/api")!
    var transport: LineTransport = HTTP.liveLines

    /// The installed models that can chat, by name. Embedding models are left out.
    func models() async throws -> [String] {
        let body = try await send(URLRequest(url: Self.base.appending(path: "tags")))
        return body["models"]?.items.compactMap { $0["name"]?.text }.filter { !$0.contains("embed") }.sorted() ?? []
    }

    /// One reply, read as it is written: the assistant message, which holds text, tool calls, or both.
    /// `onText` is given the answer's text so far, each time it grows.
    func chat(
        model: String, messages: [JSONValue], tools: [JSONValue], params: ChatParams = ChatParams(),
        onText: @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> JSONValue {
        var request = URLRequest(url: Self.base.appending(path: "chat"))
        request.httpMethod = "POST"
        // A large local model can take minutes on a long file.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "model": .string(model), "stream": .bool(true), "messages": .array(messages), "tools": .array(tools),
            // Models that reason first take about eight times longer per round for the same tool calls (measured with qwen3:14b),
            // so they do it only when the chat asks to see the reasoning.
            "think": .bool(params.thinks),
            // Ollama's default context is too small for the tool list plus a file.
            "options": .object(["num_ctx": .number(16384)].merging(params.temperature.map { ["temperature": .number($0)] } ?? [:]) { $1 }),
        ]))
        let (lines, response) = try await open(request)
        var (text, calls, sawMessage, raw, thinking) = ("", [JSONValue](), false, "", "")
        // Each line is one piece of the reply as its own JSON document.
        for try await line in lines where !line.trimmed.isEmpty {
            raw += line
            guard let piece = try? JSONValue.parse(line) else { continue }
            if let failure = piece["error"]?.text { throw OllamaError.server(status: response.statusCode, message: failure) }
            guard let message = piece["message"] else { continue }
            sawMessage = true
            calls += message["tool_calls"]?.items ?? []
            thinking += message["thinking"]?.text ?? ""
            if let more = message["content"]?.text, !more.isEmpty {
                text += more
                await onText(OllamaAgent.withoutThinking(text))
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaError.server(status: response.statusCode, message: (try? JSONValue.parse(raw))?["error"]?.text ?? "no details")
        }
        guard sawMessage else { throw OllamaError.unreadableResponse }
        var reply: [String: JSONValue] = ["role": .string("assistant"), "content": .string(text)]
        if !calls.isEmpty { reply["tool_calls"] = .array(calls) }
        if !thinking.trimmed.isEmpty { reply["thinking"] = .string(thinking) }
        return .object(reply)
    }

    private func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw OllamaError.notRunning
        }
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let (lines, response) = try await open(request)
        var raw = ""
        for try await line in lines { raw += line }
        guard let body = try? JSONValue.parse(raw) else {
            // An error page may not be JSON; the status is reported either way.
            guard (200..<300).contains(response.statusCode) else {
                throw OllamaError.server(status: response.statusCode, message: "no details")
            }
            throw OllamaError.unreadableResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaError.server(status: response.statusCode, message: body["error"]?.text ?? "no details")
        }
        return body
    }
}

/// Answers one turn with a local Ollama model: sends the conversation, runs the tools it asks for, and repeats until it has an answer.
struct OllamaAgent: Sendable {
    let client: OllamaClient
    let model: String
    let box: AgentToolbox
    var limit = 12
    /// Given the whole answer so far, each time more of it arrives.
    var onText: @MainActor @Sendable (String) -> Void = { _ in }
    var params = ChatParams()
    var onActivity: @MainActor @Sendable (String) -> Void = { _ in }
    /// What fits in the context asked for in `OllamaClient.chat`, leaving room for the tools and the answer. Ollama cuts longer input without saying so, so it is refused here instead.
    static let characterLimit = 40_000

    private var tools: [JSONValue] {
        box.tools.map { tool in
            .object(["type": .string("function"), "function": .object([
                "name": .string(tool.name), "description": .string(tool.about), "parameters": tool.schema,
            ])])
        }
    }

    func answer(_ conversation: [ChatTurn], context: String) async throws -> String {
        let characters = conversation.reduce(0) { $0 + $1.text.count }
        guard characters <= Self.characterLimit else { throw OllamaError.tooLong(characters: characters) }
        // The instructions and tools never change, so Ollama reads them once and reuses that work on every later message.
        // What does change (the time, the tags, what is remembered) goes at the very end, with the newest message.
        // Measured with qwen3:14b: re-reading the 4,000 tokens of tools and instructions takes about 15 seconds.
        var messages: [JSONValue] = [
            .object(["role": .string("system"), "content": .string(
                ClaudeAgent.instructions(web: false) + (params.suggests ? "\n\n" + ChatText.followUpRule : "")
            )]),
        ] + conversation.enumerated().map { index, turn in
            let isNewest = index == conversation.count - 1
            return .object([
                "role": .string(turn.fromUser ? "user" : "assistant"),
                "content": .string(isNewest ? "\(turn.text)\n\n<context>\n\(context)\n</context>" : turn.text),
            ])
        }
        for round in 0..<limit {
            // Ollama sends nothing while it writes a tool call, so a long one (a page) looks like a pause; say so.
            await onActivity(round == 0 ? "Thinking" : "Working on the next step (a page or a long answer can take a minute or two)")
            let reply = try await client.chat(model: model, messages: messages, tools: tools, params: params) { text in
                onActivity("Writing the reply")
                onText(text)
            }
            if let thought = reply["thinking"]?.text { await box.report(ChatStep(thought: thought)) }
            let text = Self.withoutThinking(reply["content"]?.text ?? "")
            messages.append(reply)
            let calls = reply["tool_calls"]?.items ?? []
            guard !calls.isEmpty else { return text }
            // What it says before using a tool stays where it was said, between the steps.
            if !text.isEmpty { await box.report(ChatStep(narration: text)) }
            await onText("")
            for call in calls {
                guard let name = call["function"]?["name"]?.text else { throw OllamaError.unreadableResponse }
                let outcome = await box.runAsync(name, ToolInput(value: call["function"]?["arguments"] ?? .object([:])))
                messages.append(.object(["role": .string("tool"), "tool_name": .string(name), "content": .string(outcome.text)]))
            }
        }
        throw OllamaError.tooManySteps
    }

    /// Some models write their reasoning into the answer between <think> tags; the user is shown the answer only.
    static func withoutThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression).trimmed
    }
}
