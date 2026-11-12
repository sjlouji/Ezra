import Foundation
import SwiftData
import Testing
@testable import Ezra

@MainActor
struct OllamaTests {
    private let tags = #"{"models": [{"name": "qwen3:14b"}, {"name": "nomic-embed-text:latest"}, {"name": "mistral:latest"}]}"#

    @Test func installedChatModelsAreListedAndTheFirstIsChosen() async throws {
        let (_, container) = try makeWorkspace()
        let chat = makeChat(container, engine: .ollama, transport: FakeClaude([(200, tags), (200, #"{"models": []}"#)]).transport)
        #expect(chat.unavailableReason == "Choose an Ollama model in Settings to use Ollama.")
        await chat.refreshOllama()
        #expect(chat.ollamaModels == ["mistral:latest", "qwen3:14b"] && chat.ollamaModel == "mistral:latest")
        #expect(chat.unavailableReason == nil && chat.ollamaProblem == nil)
        await chat.refreshOllama()
        #expect(chat.ollamaModel == nil && chat.ollamaProblem?.hasPrefix("Ollama has no chat models installed.") == true)
    }

    @Test func ollamaRunsToolsMakesPagesAndHidesItsThinking() async throws {
        let (workspace, container) = try makeWorkspace()
        let round = """
            {"message": {"role": "assistant", "content": "", "thinking": "plan", "tool_calls": [
              {"function": {"name": "addTask", "arguments": {"title": "Call the bank", "when": "tomorrow", "tags": ["Admin"]}}},
              {"function": {"name": "showPage", "arguments": {"title": "Chart", "html": "<svg></svg>"}}}]}}
            """
        let final = #"{"message": {"role": "assistant", "content": "<think>done?</think>Added **Call the bank** for tomorrow."}}"#
        let ollama = FakeClaude([(200, tags), (200, round), (200, final)])
        let chat = makeChat(container, engine: .ollama, transport: ollama.transport)
        await chat.refreshOllama()
        chat.ollamaModel = "qwen3:14b"

        await chat.send("Add a task to call the bank tomorrow and chart it")

        #expect(try workspace.findToDo("Call the bank").tags == ["Admin"])
        let reply = try #require(chat.messages.last)
        #expect(reply.role == .assistant && reply.text == "Added **Call the bank** for tomorrow.")
        #expect(reply.steps.map(\.tool) == ["thinking", "addTask", "showPage"] && reply.steps[2].page?.title == "Chart" && reply.steps[0].result == "plan")
        let first = try ollama.body(1)
        #expect(first["model"] == .string("qwen3:14b") && first["stream"] == .bool(true))
        #expect(first["tools"]?.items.count == AgentTools.all.count)
        #expect(first["messages"]?.items.first?["content"]?.text?.contains("You cannot reach the web.") == true)
        // Nothing that changes from minute to minute is in the part Ollama keeps; it rides with the newest message.
        #expect(first["messages"]?.items.first?["content"]?.text?.contains("Now: ") == false)
        #expect(first["messages"]?.items.last?["content"]?.text?.contains("<context>\nNow: ") == true)
        let second = try ollama.body(2)["messages"]?.items ?? []
        #expect(second.suffix(2).map { $0["role"]?.text } == ["tool", "tool"])
        #expect(second.last?["tool_name"] == .string("showPage"))
    }

    @Test func aConversationTooLongForOllamaIsRefusedNotCut() async throws {
        let (_, container) = try makeWorkspace()
        let chat = makeChat(container, engine: .ollama, transport: FakeClaude([(200, tags)]).transport)
        await chat.refreshOllama()
        await chat.send("Summarise", files: [ChatFile(name: "long.txt", text: String(repeating: "word ", count: 10_000))])
        #expect(chat.messages.last?.role == .failure)
        #expect(chat.messages.last?.text.hasPrefix("This conversation is too long for the Ollama model") == true)
    }

    @Test func aStoppedOllamaIsReportedPlainly() async throws {
        let (_, container) = try makeWorkspace()
        let chat = makeChat(container, engine: .ollama, transport: { _ in throw URLError(.cannotConnectToHost) })
        await chat.refreshOllama()
        #expect(chat.ollamaModels.isEmpty && chat.ollamaProblem == "Ollama is not running on this Mac. Open the Ollama app, then try again.")
    }

    /// Talks to the real Ollama on this Mac, from inside the app's sandbox. Run with TEST_RUNNER_EZRA_LIVE_OLLAMA=<model name>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_LIVE_OLLAMA"] != nil))
    func liveOllamaAddsAReminderAndMakesAPage() async throws {
        let (workspace, container) = try makeWorkspace()
        try workspace.addProject(name: "Website")
        try workspace.addToDo(title: "Write copy", project: try workspace.findProject("Website"))
        let chat = makeChat(container, engine: .ollama)
        await chat.refreshOllama()
        chat.ollamaModel = try #require(ProcessInfo.processInfo.environment["EZRA_LIVE_OLLAMA"])

        await chat.send("Remind me tonight at 9 pm to surprise my wife")
        let task = try workspace.tasks().first { $0.title.localizedCaseInsensitiveContains("wife") }
        let hour = task?.reminderAt.map { Calendar.current.component(.hour, from: $0) }
        #expect(hour == 21, "\(chat.messages.last?.text ?? "") \(chat.messages.last?.steps.map(\.detail) ?? [])")
        #expect(task?.tags.isEmpty == false)

        await chat.send("Make a small bar chart page of my open to-dos per project")
        let page = chat.messages.last?.steps.compactMap(\.page).first
        #expect(page?.html.localizedCaseInsensitiveContains("<") == true, "\(chat.messages.last?.text ?? "") \(chat.messages.last?.steps.map(\.label) ?? [])")
        if let page { Attachment.record(Data(page.html.utf8), named: "ollama-page.html") }
    }

    /// The real model answers the request the user made, with a dashboard of real figures. Run with TEST_RUNNER_EZRA_LIVE_OLLAMA=<model name>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_LIVE_OLLAMA"] != nil))
    func liveOllamaShowsADashboard() async throws {
        let (workspace, container) = try makeWorkspace()
        for (name, count) in [("Website", 3), ("Taxes", 1)] {
            let project = try workspace.addProject(name: name)
            for index in 0..<count { try workspace.addToDo(title: "\(name) task \(index + 1)", project: project) }
        }
        let chat = makeChat(container, engine: .ollama)
        await chat.refreshOllama()
        chat.ollamaModel = try #require(ProcessInfo.processInfo.environment["EZRA_LIVE_OLLAMA"])
        let began = Date.now
        await chat.send("Create an artifact on my work load")
        let steps = chat.messages.last?.steps ?? []
        let built = steps.last { $0.page != nil && $0.state == .done }
        #expect(built?.tool == "showWorkload", "\(chat.messages.last?.text ?? "") | \(steps.map { "\($0.tool) \($0.state.rawValue): \($0.result.prefix(160))" })")
        #expect(built?.page?.html.contains("Website") == true)
        print("EZRA-TIMELINE total \(Int(Date.now.timeIntervalSince(began)))s")
        for step in steps { print("EZRA-TIMELINE \(step.tool) \(step.state.rawValue) \(step.seconds.map { String(format: "%.1fs", $0) } ?? "-") \((step.subject ?? step.result).prefix(120))") }
    }

    /// Saves the exact request sent to Ollama for a first message, so its size and speed can be measured outside the app.
    /// Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"))
    func theRequestSentToOllamaIsOnRecord() async throws {
        let (_, container) = try makeWorkspace()
        let ollama = FakeClaude([(200, tags), (200, #"{"message": {"role": "assistant", "content": "Hi"}}"#)])
        let chat = makeChat(container, engine: .ollama, transport: ollama.transport)
        await chat.refreshOllama()
        await chat.send("Create an artifact on my work load")
        Attachment.record(try #require(ollama.requests[1].httpBody), named: "ollama-request.json")
    }
}
