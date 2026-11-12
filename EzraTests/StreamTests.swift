import Foundation
import SwiftData
import Testing
@testable import Ezra

@MainActor
struct StreamTests {
    @MainActor final class Seen { var texts: [String] = [] }

    /// A Claude reply as the API streams it: thinking, text in two pieces, then a tool call whose arguments arrive in fragments.
    private let events = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}
        data: {"type":"content_block_stop","index":0}
        event: ping
        data: {"type":"ping"}
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Adding "}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"it now."}}
        data: {"type":"content_block_stop","index":1}
        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_7","name":"addTask","input":{}}}
        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"title\\": \\"Call"}}
        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":" the bank\\", \\"tags\\": [\\"Admin\\"]}"}}
        data: {"type":"content_block_stop","index":2}
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}
        data: {"type":"message_stop"}
        """

    @Test func aStreamedClaudeReplyIsShownAsItArrivesAndPutBackTogetherExactly() async throws {
        let claude = FakeClaude([(200, events)])
        let seen = Seen()
        let reply = try await ClaudeClient(key: "k", transport: claude.transport).send(system: "s", tools: [], messages: []) { seen.texts.append($0) }
        #expect(seen.texts == ["Adding ", "Adding it now."])
        #expect(reply.stopReason == "tool_use" && reply.content.count == 3)
        #expect(reply.content[0] == .object(["type": .string("thinking"), "thinking": .string("plan"), "signature": .string("sig-1")]))
        #expect(reply.content[1]["text"] == .string("Adding it now."))
        #expect(reply.content[2]["input"] == .object(["title": .string("Call the bank"), "tags": .array([.string("Admin")])]) && reply.content[2]["id"] == .string("toolu_7"))
        #expect(try claude.body(0)["stream"] == .bool(true))
    }

    @Test func aStreamedTurnRunsItsToolAndEndsWithTheSecondReply() async throws {
        let (workspace, container) = try makeWorkspace()
        let end = """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done."}}
            data: {"type":"content_block_stop","index":0}
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
            """
        let chat = makeChat(container, engine: .claude, key: "k", transport: FakeClaude([(200, events), (200, end)]).transport)
        await chat.send("Add a task to call the bank")
        #expect(try workspace.findToDo("Call the bank").title == "Call the bank")
        // What it said before the tool stays in place among the steps; the reply is its closing words.
        let reply = try #require(chat.messages.last)
        #expect(reply.text == "Done." && reply.steps.map(\.tool) == ["thinking", "say", "addTask"] && reply.steps[1].result == "Adding it now.")
        let call = reply.steps[2]
        #expect(call.subject == "Call the bank" && call.seconds != nil && call.input?.contains("\"title\" : \"Call the bank\"") == true)
    }

    @Test func streamErrorsAreReported() async throws {
        let failing = FakeClaude([
            (200, #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#),
            (200, "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"),
        ])
        let client = ClaudeClient(key: "k", transport: failing.transport)
        await #expect(throws: ClaudeError.server(status: 200, message: "Overloaded")) { try await client.send(system: "", tools: [], messages: []) }
        await #expect(throws: ClaudeError.server(status: 429, message: "slow down")) { try await client.send(system: "", tools: [], messages: []) }
        // A stream that stops without saying why it stopped is not treated as a finished answer.
        await #expect(throws: ClaudeError.unreadableResponse) { try await client.send(system: "", tools: [], messages: []) }
    }

    @Test func aStreamedOllamaReplyGrowsWordByWord() async throws {
        let pieces = """
            {"message":{"role":"assistant","content":"Two "},"done":false}
            {"message":{"role":"assistant","content":"things."},"done":false}
            {"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"listTasks","arguments":{"list":"today"}}}]},"done":true}
            """
        let seen = Seen()
        let reply = try await OllamaClient(transport: FakeClaude([(200, pieces)]).transport)
            .chat(model: "m", messages: [], tools: []) { seen.texts.append($0) }
        #expect(seen.texts == ["Two", "Two things."])
        #expect(reply["content"] == .string("Two things.") && reply["tool_calls"]?.items.count == 1)
        let broken = OllamaClient(transport: FakeClaude([(200, #"{"error":"model not found"}"#)]).transport)
        await #expect(throws: OllamaError.server(status: 200, message: "model not found")) { try await broken.chat(model: "m", messages: [], tools: []) }
    }
}
