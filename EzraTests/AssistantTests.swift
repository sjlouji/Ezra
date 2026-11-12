import Foundation
import SwiftData
import Testing
@testable import Ezra

private let calendar = Calendar.current
private func at(_ hour: Int, day offset: Int = 0) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!)!
}

/// A chat that never touches the real Keychain or the app's own preferences.
@MainActor
func makeChat(
    _ container: ModelContainer, engine: AssistantEngine = .onDevice, key: String? = nil, transport: @escaping LineTransport = HTTP.liveLines
) -> ChatModel {
    let stored = KeyBox(key)
    let chat = ChatModel(
        container: container, reminders: nil, transport: transport,
        defaults: UserDefaults(suiteName: "ezra-tests-\(UUID().uuidString)")!,
        readKey: { stored.value.map { Data($0.utf8) } },
        writeKey: { stored.value = $0.flatMap { String(data: $0, encoding: .utf8) } }
    )
    chat.engine = engine
    return chat
}

@MainActor final class KeyBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

/// Stands in for the Claude API: answers each request with the next scripted reply and keeps what it was sent.
final class FakeClaude: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [(Int, String)]) { self.replies = replies }

    /// Replies are handed over line by line, as the real connection does. A scripted reply written across several
    /// lines for readability is sent as one line unless it is an event stream.
    var transport: LineTransport {
        { request in
            let (status, body) = self.lock.withLock {
                self.requests.append(request)
                return self.replies.isEmpty ? (500, #"{"error":{"message":"no reply scripted"}}"#) : self.replies.removeFirst()
            }
            let isEvents = body.hasPrefix("event:") || body.hasPrefix("data:") || body.hasPrefix("{\"message\"") && body.contains("\n{")
            let lines = isEvents ? body.components(separatedBy: "\n") : [body.replacingOccurrences(of: "\n", with: " ")]
            let stream = AsyncThrowingStream<String, Error> { continuation in
                lines.forEach { continuation.yield($0) }
                continuation.finish()
            }
            return (stream, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func body(_ index: Int) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(requests[index].httpBody))
    }
}

@MainActor
struct AssistantToolTests {
    @MainActor final class StepLog { var steps: [ChatStep] = [] }

    private func makeToolbox() throws -> (AgentToolbox, Workspace, StepLog) {
        let (workspace, container) = try makeWorkspace()
        let log = StepLog()
        return (AgentToolbox(container: container, reminders: nil) { log.steps.append($0) }, workspace, log)
    }

    private func input(_ json: String) throws -> ToolInput { ToolInput(value: try JSONValue.parse(json)) }

    @Test func addTaskCreatesATaggedTaskWithAReminderAndReportsTheStep() throws {
        let (box, workspace, log) = try makeToolbox()
        try workspace.addProject(name: "Family")
        let reminder = DayText.string(moment: at(21))
        let outcome = box.run("addTask", try input("""
            {"title": "Surprise my wife", "project": "family", "reminder": "\(reminder)",
             "tags": ["Personal", "personal", " Home "], "checklist": ["Buy flowers", "Book dinner"]}
            """))
        let task = try workspace.findToDo("Surprise my wife")
        #expect(!outcome.failed && outcome.todos == [task.uuid])
        #expect(task.project?.name == "Family" && task.tags == ["Personal", "Home"])
        #expect(task.reminderAt == at(21))
        // A reminder with no day said puts the task on that day.
        #expect(task.when == .dated && task.startDate == calendar.startOfDay(for: .now))
        #expect(task.sortedChecklist.map(\.title) == ["Buy flowers", "Book dinner"])
        #expect(log.steps.map(\.state) == [.running, .done])
        #expect(log.steps.last?.label == "Add to-do" && log.steps.last?.changed == true && log.steps.last?.todos == [task.uuid])
        #expect(log.steps.first?.id == log.steps.last?.id)
    }

    @Test func aFailedToolTellsTheModelShowsAFailedStepAndChangesNothing() throws {
        let (box, workspace, log) = try makeToolbox()
        let outcome = box.run("addTask", try input(#"{"title": "Orphan", "project": "Nowhere"}"#))
        #expect(outcome.failed && outcome.text.hasPrefix("Error: No project matches"))
        #expect(try workspace.tasks().isEmpty)
        #expect(log.steps.last?.state == .failed)
        #expect(box.run("noSuchTool", try input("{}")).failed)
        // Claude and Ollama must give every required argument; a skipped one is sent back to be filled in.
        var strict = box
        strict.strict = true
        #expect(strict.run("addTask", try input(#"{"title": "Untagged"}"#)).text.contains("the \"tags\" argument is missing or empty"))
        #expect(strict.run("addTask", try input(#"{"title": "Untagged", "tags": []}"#)).failed)
        #expect(try workspace.tasks().isEmpty)
        // The on-device model is let through without tags.
        #expect(!box.run("addTask", try input(#"{"title": "Plain"}"#)).failed)
    }

    @Test func muddledDateArgumentsStillMeanWhatWasSaid() throws {
        let (box, workspace, _) = try makeToolbox()
        let nine = try DayText.moment(from: "2026-11-13 21:00")
        // The time in "when" and words in "reminder", as the small on-device model sends them.
        _ = box.run("addTask", try input(#"{"title": "A", "when": "2026-11-13 21:00", "reminder": "I have to surprise my wife"}"#))
        _ = box.run("addTask", try input(#"{"title": "B", "when": "2026-11-13", "reminder": "21:00"}"#))
        _ = box.run("addTask", try input(#"{"title": "C", "reminder": "2026-11-13 21:00"}"#))
        for title in ["A", "B", "C"] {
            let task = try workspace.findToDo(title)
            #expect(task.reminderAt == nine && task.startDate == Calendar.current.startOfDay(for: nine), "\(title)")
        }
        // Words alone, with no time anywhere, are still refused.
        #expect(box.run("addTask", try input(#"{"title": "D", "when": "tomorrow", "reminder": "in the evening"}"#)).failed)
    }

    @Test func updateTaskChangesStatusTagsAndPlan() throws {
        let (box, workspace, _) = try makeToolbox()
        let task = try workspace.addToDo(title: "Renew passport", tags: ["Admin"])
        _ = box.run("updateTask", try input(#"{"title": "renew passport", "when": "someday", "tags": ["Travel", "Urgent"], "newTitle": "Renew my passport"}"#))
        #expect(task.when == .someday && task.tags == ["Travel", "Urgent"] && task.title == "Renew my passport")
        _ = box.run("updateTask", try input(#"{"title": "passport", "when": "tonight"}"#))
        #expect(task.evening && task.startDate == calendar.startOfDay(for: .now) && task.tags == ["Travel", "Urgent"])
        _ = box.run("updateTask", try input(#"{"title": "passport", "status": "done"}"#))
        #expect(task.isCompleted)
        _ = box.run("updateTask", try input(#"{"title": "passport", "status": "open"}"#))
        #expect(!task.isCompleted)
        _ = box.run("completeTask", try input(#"{"title": "passport"}"#))
        #expect(task.isCompleted)
    }

    @Test func projectsAreasNotesAndEventsAreCreated() throws {
        let (box, workspace, _) = try makeToolbox()
        let made = box.run("addProject", try input(#"{"name": "Trip to the hills", "area": "Family", "notes": "Two days.", "tasks": ["Book cabin", "Pack"]}"#))
        let project = try workspace.findProject("Trip")
        #expect(made.text == "Created project Trip to the hills in area Family with 2 tasks")
        #expect(project.area?.name == "Family" && project.details == "Two days." && project.openTasks.map(\.title) == ["Book cabin", "Pack"])
        #expect(box.run("addArea", try input(#"{"name": "family"}"#)).text == "The area Family already exists.")
        #expect(box.run("addArea", try input(#"{"name": "Health"}"#)).text == "Created area Health")
        #expect(box.run("listAreasAndTags", try input("{}")).text.contains("Areas: Family, Health"))

        _ = box.run("writeNote", try input(#"{"title": "Ideas", "text": "first"}"#))
        _ = box.run("writeNote", try input(#"{"title": "ideas", "text": "second"}"#))
        #expect(try workspace.notes().map(\.body) == ["first\n\nsecond"])

        #expect(box.run("addEvent", try input(#"{"title": "Call Sam", "day": "tomorrow", "start": "15:00"}"#)).text.hasPrefix("Added event Call Sam"))
        let event = try #require(try workspace.events().first)
        #expect(event.start == at(15, day: 1) && event.end == at(16, day: 1))
        #expect(box.run("listEvents", try input(#"{"day": "tomorrow"}"#)).text == "- 15:00–16:00 Call Sam")
        #expect(box.run("addEvent", try input(#"{"title": "X", "day": "today", "start": "3pm"}"#)).failed)
    }

    @Test func showTasksGivesTheChatATableOfTheMatchingToDos() throws {
        let (box, workspace, log) = try makeToolbox()
        let first = try workspace.addToDo(title: "Pay rent", schedule: .on(.now), tags: ["Home"])
        try workspace.addToDo(title: "Write report", schedule: .on(.now), tags: ["Work"])
        #expect(box.run("listTasks", try input(#"{"list": "today"}"#)).text.contains("- Write report [when:"))
        let shown = box.run("showTasks", try input(#"{"title": "Home today", "list": "today", "tag": "home"}"#))
        #expect(shown.table == ChatTable(title: "Home today", todos: [first.uuid]))
        #expect(log.steps.last?.table?.todos == [first.uuid])
        #expect(box.run("showTasks", try input(#"{"title": "None", "list": "someday"}"#)).table == nil)
    }

    @Test func everyToolIsDescribedForBothModels() throws {
        let (box, _, _) = try makeToolbox()
        let schema = AgentTools.addTask.schema
        #expect(schema["required"] == .array([.string("title"), .string("tags")]))
        #expect(schema["properties"]?["tags"]?["type"] == .string("array"))
        #expect(AgentTools.listTasks.schema["properties"]?["list"]?["enum"]?.items.count == 7)
        #expect(Set(AgentTools.all.map(\.name)).count == AgentTools.all.count)
        for tool in AgentTools.all where tool.onDevice {
            #expect(throws: Never.self) { try OnDeviceTool(tool, box: box) }
        }
    }
}

@MainActor
struct ClaudeChatTests {
    private let toolRound = """
        {"stop_reason": "tool_use", "content": [
          {"type": "thinking", "thinking": "", "signature": "sig"},
          {"type": "server_tool_use", "id": "srv1", "name": "web_search", "input": {"query": "flower shops open late"}},
          {"type": "web_search_tool_result", "tool_use_id": "srv1", "content": [
            {"type": "web_search_result", "title": "Bloom & Co", "url": "https://example.com/bloom"}]},
          {"type": "tool_use", "id": "toolu_1", "name": "addTask", "input": {"title": "Buy flowers", "when": "today", "tags": ["Personal"]}}
        ]}
        """
    private let finalRound = """
        {"stop_reason": "end_turn", "content": [
          {"type": "text", "text": "Done: **Buy flowers** is on today. "},
          {"type": "text", "text": "Bloom & Co is open late.", "citations": []}
        ]}
        """

    @Test func claudeRunsItsToolsShowsEveryStepAndSavesTheReply() async throws {
        let (workspace, container) = try makeWorkspace()
        let claude = FakeClaude([(200, toolRound), (200, finalRound)])
        let chat = makeChat(container, engine: .claude, key: "test-key", transport: claude.transport)
        #expect(chat.unavailableReason == nil)

        await chat.send("Add buy flowers for today and find a shop")

        let task = try workspace.findToDo("Buy flowers")
        #expect(task.tags == ["Personal"] && task.startDate == calendar.startOfDay(for: .now))
        let reply = try #require(chat.messages.last)
        #expect(reply.role == .assistant && reply.text == "Done: **Buy flowers** is on today. Bloom & Co is open late.")
        #expect(reply.steps.map(\.tool) == ["web_search", "addTask"])
        #expect(reply.steps[0].detail == "flower shops open late" && reply.steps[0].sources.map(\.url) == ["https://example.com/bloom"])
        #expect(reply.steps[1].state == .done && reply.steps[1].todos == [task.uuid])
        // Saved with the conversation, so it is there after a restart and on other devices.
        #expect(try chat.thread?.sortedMessages.last?.steps().count == 2)

        let first = try claude.body(0)
        #expect(claude.requests[0].value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(first["model"] == .string("claude-opus-5-5"))
        #expect(first["tools"]?.items.contains { $0["type"] == .string("web_search_20260209") } == true)
        #expect(first["tools"]?.items.contains { $0["name"] == .string("showTasks") } == true)
        // The second request returns Claude's own blocks untouched, then the tool's result.
        let second = try claude.body(1)["messages"]?.items ?? []
        #expect(second.count == 3 && second[1]["content"]?.items.first?["signature"] == .string("sig"))
        let result = second[2]["content"]?.items.first
        #expect(result?["tool_use_id"] == .string("toolu_1") && result?["is_error"] == .bool(false))
        #expect(result?["content"]?.text?.hasPrefix("Added task Buy flowers") == true)
    }

    @Test func earlierTurnsAreSentToClaudeAndFailuresAreShownNotHidden() async throws {
        let (_, container) = try makeWorkspace()
        let claude = FakeClaude([
            (200, finalRound),
            (200, #"{"stop_reason": "refusal", "stop_details": {"explanation": "Not allowed."}, "content": []}"#),
            (401, #"{"error": {"message": "invalid x-api-key"}}"#),
        ])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        await chat.send("First")
        await chat.send("Second")
        #expect(chat.messages.last?.role == .failure && chat.messages.last?.text == "Claude declined to answer this. Not allowed.")
        let sent = try claude.body(1)["messages"]?.items ?? []
        #expect(sent.map { $0["role"]?.text } == ["user", "assistant", "user"])
        await chat.send("Third")
        #expect(chat.messages.last?.text == "Claude did not accept the API key. Check it in Settings.")
        // A failed turn is not replayed to Claude as if it were an answer.
        #expect(try claude.body(2)["messages"]?.items.count == 4)
    }

    @Test func claudeNeedsAKeyAndRemovingItGoesBackToTheMac() throws {
        let (_, container) = try makeWorkspace()
        let chat = makeChat(container, engine: .claude)
        #expect(chat.unavailableReason == "Add your Claude API key in Settings to use Claude.")
        try chat.setClaudeKey("  sk-test \n")
        #expect(chat.hasClaudeKey && chat.unavailableReason == nil)
        try chat.setClaudeKey(nil)
        #expect(!chat.hasClaudeKey && chat.engine == .onDevice)
    }

    @Test func conversationsAreSavedPinnedRenamedReopenedAndDeleted() throws {
        let (workspace, container) = try makeWorkspace()
        let chat = makeChat(container)
        #expect(chat.messages.isEmpty && chat.thread == nil)

        try chat.record(.user, "Plan my week")
        try chat.record(.assistant, "Here is a plan.")
        let first = try #require(chat.thread)
        #expect(first.title == "Plan my week" && chat.messages.map(\.text) == ["Plan my week", "Here is a plan."])
        chat.togglePin(first)
        chat.rename(first, to: " Weekly plan ")
        chat.rename(first, to: "  ")
        #expect(first.pinned && first.title == "Weekly plan")

        chat.newChat()
        #expect(chat.messages.isEmpty)
        try chat.record(.user, "Something else")
        #expect(try workspace.context.fetchCount(FetchDescriptor<ChatThread>()) == 2)

        chat.open(first)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        chat.delete(first)
        #expect(chat.thread == nil)
        #expect(try workspace.context.fetch(FetchDescriptor<ChatThread>()).map(\.title) == ["Something else"])
        #expect(try workspace.context.fetchCount(FetchDescriptor<ChatMessage>()) == 1)
    }
}

/// These talk to the real on-device model. Run with TEST_RUNNER_EZRA_LIVE_MODEL=1.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EZRA_LIVE_MODEL"] == "1"))
struct LiveOnDeviceModelTests {
    @Test func addsATaskAndAnswersFromTheStore() async throws {
        let (workspace, container) = try makeWorkspace()
        try workspace.addToDo(title: "Renew car insurance", schedule: .on(.now))
        let chat = makeChat(container)

        await chat.send("Add a task called Buy oat milk for tomorrow")
        #expect(chat.messages.last?.role == .assistant, "\(chat.messages.last?.text ?? "")")
        let added = try workspace.tasks().first { $0.title.localizedCaseInsensitiveContains("oat milk") }
        #expect(added?.startDate == SmartList.startOfTomorrow(now: .now, calendar: .current))
        #expect(
            chat.messages.last?.steps.contains { $0.tool == "addTask" && $0.state == .done } == true,
            "\(chat.messages.last?.text ?? "") | \(chat.messages.last?.steps.map { "\($0.tool) \($0.state.rawValue): \($0.detail) -> \($0.result)" } ?? [])"
        )

        await chat.send("What do I have to do today?")
        #expect(chat.messages.last?.text.localizedCaseInsensitiveContains("insurance") == true, "\(chat.messages.last?.text ?? "")")
    }

    @Test func aSpokenReminderBecomesATaskWithAReminderTime() async throws {
        let (workspace, container) = try makeWorkspace()
        let chat = makeChat(container)
        // Tomorrow, so the time asked for is never already past when the test runs.
        await chat.send("Create a reminder for tomorrow night 9 pm telling that I have to surprise my wife")
        let reply = chat.messages.last
        let task = try workspace.tasks().first
        #expect(task?.reminderAt == at(21, day: 1), "\(reply?.text ?? "") \(reply?.steps.map(\.detail) ?? [])")
        #expect(task?.tags.isEmpty == false, "no tags: \(reply?.steps.map(\.detail) ?? [])")
    }

    @Test func putsAMeetingOnTheCalendar() async throws {
        let (workspace, container) = try makeWorkspace()
        let chat = makeChat(container)
        await chat.send("Schedule a meeting with Sam tomorrow from 3pm to 4pm")
        let reply = chat.messages.last?.text ?? ""
        let event = try workspace.events().first
        #expect(event?.start == at(15, day: 1), "\(reply)")
        #expect(event?.title.localizedCaseInsensitiveContains("Sam") == true, "\(reply)")
    }
}
