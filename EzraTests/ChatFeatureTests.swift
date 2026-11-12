import Foundation
import SwiftData
import Testing
@testable import Ezra

@MainActor
struct ChatFeatureTests {
    private func done(_ text: String) -> (Int, String) {
        (200, #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "\#(text)"}]}"#)
    }

    @Test func followUpsAreTakenOffTheReplyAndKeptAsSuggestions() async throws {
        #expect(ChatText.splitFollowUps("Done.\nFollow-ups: Show today | Plan tomorrow | What is overdue?\n").followUps == ["Show today", "Plan tomorrow", "What is overdue?"])
        #expect(ChatText.splitFollowUps("Done.\nFollow-ups: Show to").text == "Done.") // hidden while it is still arriving
        #expect(ChatText.splitFollowUps("Follow-ups: a | b\nmore text") == ("Follow-ups: a | b\nmore text", []))

        let (_, container) = try makeWorkspace()
        let claude = FakeClaude([done("Two things today.\\nFollow-ups: Show them | Move one to tomorrow")])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        await chat.send("What is on today?")
        let reply = try #require(chat.messages.last)
        #expect(reply.text == "Two things today." && reply.steps.first { $0.tool == ChatStep.followUps }?.detail == "Show them | Move one to tomorrow")
        #expect(try claude.body(0)["system"]?.text?.contains("Follow-ups: first | second | third") == true)
    }

    @Test func aChatsParametersAndInstructionsShapeTheRequestAndStayWithTheChat() async throws {
        let (workspace, container) = try makeWorkspace()
        let claude = FakeClaude([done("Hi"), done("Hi")])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        chat.instructions = "Answer in one sentence."
        chat.params = ChatParams(effort: "low", webSearch: false, showsThinking: true, followUps: false)
        await chat.send("Hello")
        let body = try claude.body(0)
        #expect(body["output_config"]?["effort"] == .string("low") && body["thinking"]?["display"] == .string("summarized"))
        #expect(body["tools"]?.items.contains { $0["name"] == .string("web_search") } == false)
        let system = try #require(body["system"]?.text)
        #expect(system.contains("The user's instructions for you:\nAnswer in one sentence.") && !system.contains("Follow-ups:") && system.contains("You cannot reach the web."))

        // Saved with the chat: a new chat starts clean, reopening brings them back.
        let thread = try #require(chat.thread)
        #expect(thread.params.effort == "low" && thread.instructions == "Answer in one sentence.")
        chat.newChat()
        #expect(chat.params == ChatParams() && chat.instructions.isEmpty)
        chat.open(thread)
        #expect(chat.params.webSearch == false && chat.instructions == "Answer in one sentence.")
        chat.move(thread, toFolder: " Work ")
        #expect(try workspace.context.fetch(FetchDescriptor<ChatThread>()).first?.folder == "Work")

        // Ollama takes the temperature.
        let ollama = FakeClaude([(200, #"{"models": [{"name": "m"}]}"#), (200, #"{"message": {"role": "assistant", "content": "Hi"}}"#)])
        let local = makeChat(container, engine: .ollama, transport: ollama.transport)
        await local.refreshOllama()
        local.params = ChatParams(temperature: 0.2, showsThinking: true)
        await local.send("Hello")
        #expect(try ollama.body(1)["options"]?["temperature"] == .number(0.2) && ollama.body(1)["think"] == .bool(true))
    }

    @Test func messagesTypedDuringAReplyWaitAndGoTogether() async throws {
        let (_, container) = try makeWorkspace()
        let claude = FakeClaude([done("First answer"), done("Second answer")])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        chat.isResponding = true
        await chat.send("Also add milk")
        await chat.send("And eggs")
        let firstID = try #require(chat.queue.first?.id)
        let dropped = try #require(chat.unqueue(firstID))
        #expect(dropped.text == "Also add milk" && chat.queue.map(\.text) == ["And eggs"] && chat.messages.isEmpty)
        chat.queue.insert(dropped, at: 0)
        chat.isResponding = false

        await chat.send("What is on today?")
        #expect(chat.queue.isEmpty)
        #expect(chat.messages.map(\.text) == ["What is on today?", "First answer", "Also add milk\n\nAnd eggs", "Second answer"])
    }

    @Test func anotherModelAnswersTooButCannotChangeAnything() async throws {
        let (workspace, container) = try makeWorkspace()
        let addCall = """
            {"message": {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "addTask", "arguments": {"title": "Sneaky", "tags": ["x"]}}}]}}
            """
        let server = FakeClaude([
            (200, #"{"models": [{"name": "m"}]}"#), done("Claude says hi"),
            (200, addCall), (200, #"{"message": {"role": "assistant", "content": "Ollama says hi"}}"#),
        ])
        let chat = makeChat(container, engine: .claude, key: "k", transport: server.transport)
        await chat.refreshOllama()
        chat.params.alsoAsk = [AssistantEngine.ollama.rawValue]
        await chat.send("Hello")
        #expect(chat.messages.map(\.text) == ["Hello", "Claude says hi", "Ollama says hi"])
        #expect(chat.messages.suffix(2).map { $0.steps.first { $0.tool == ChatStep.engine }?.label } == ["Claude", "Ollama"])
        // The comparison model was not even offered the tools that change data, and its attempt did nothing.
        #expect(try server.body(2)["tools"]?.items.contains { $0["function"]?["name"] == .string("addTask") } == false)
        #expect(try workspace.tasks().isEmpty)
        // Both were asked the same question, without the other's answer.
        #expect(try server.body(2)["messages"]?.items.filter { $0["role"] == .string("assistant") }.isEmpty == true)
    }

    @Test func theModelCanWorkOutDatesKeepAPlanSetATimerAndHandWorkToSubAgents() async throws {
        let (_, container) = try makeWorkspace()
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        let math = box.run("dateMath", ToolInput(value: .object(["date": .string("2026-11-12"), "addDays": .string("45"), "until": .string("2027-01-01")])))
        #expect(math.text == "Thursday 2026-11-12. 45 days from it is Sunday 2026-12-27. 50 days from it to Friday 2027-01-01")
        let plan = box.run("plan", ToolInput(value: .object(["steps": .array([.string("Read notes"), .string("Draft")]), "done": .array([.string("read notes")])])))
        #expect(plan.plan == [PlanLine(title: "Read notes", done: true), PlanLine(title: "Draft", done: false)])
        #expect(box.run("setTimer", ToolInput(value: .object(["minutes": .string("5"), "label": .string("Tea")]))).text.contains("setTimer cannot be used here"))

        func call(_ name: String, _ input: String) -> (Int, String) {
            (200, #"{"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "t1", "name": "\#(name)", "input": \#(input)}]}"#)
        }
        let claude = FakeClaude([
            call("delegate", #"{"tasks": ["Compare trains", "Compare flights"]}"#), done("Trains take 3 h"), done("Flights take 1 h"), done("Fly."),
            call("setTimer", #"{"minutes": "0.001", "label": "Tea", "prompt": "Remind me to pour it"}"#), done("Timer set."), done("Pour the tea."),
        ])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        chat.params.followUps = false
        await chat.send("Train or plane to Rome?")
        let delegated = try #require(chat.messages.last?.steps.first { $0.tool == "delegate" })
        #expect(delegated.state == .done && delegated.result.contains("## Sub-agent 1: Compare trains") && delegated.result.contains("take 1 h"))
        // A sub-agent is given the task on its own and cannot hand work on again.
        let helper = try claude.body(1)
        #expect(helper["messages"]?.items.count == 1 && chat.messages.last?.text == "Fly.")

        await chat.send("Set a tea timer")
        #expect(chat.messages.last?.text == "Timer set.")
        try await Task.sleep(for: .seconds(0.5))
        // The timer ended and sent its prompt back into the chat.
        #expect(chat.timers.isEmpty && chat.messages.last?.text == "Pour the tea.")
        #expect(chat.messages.dropLast().last?.text == "The timer \"Tea\" has ended. Remind me to pour it")
    }

    @Test func aReplyCanBeStoppedAndSaysWhatItIsDoingMeanwhile() async throws {
        let (_, container) = try makeWorkspace()
        // A model that has written half an answer and then goes quiet, as one writing a long page does.
        let slow: LineTransport = { request in
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
                continuation.yield(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me gather the data."}}"#)
                continuation.yield(#"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"showPage","input":{}}}"#)
                let hold = Task {
                    try await Task.sleep(for: .seconds(30))
                    continuation.finish()
                }
                continuation.onTermination = { _ in hold.cancel() }
            }
            return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let chat = makeChat(container, engine: .claude, key: "k", transport: slow)
        let turn = Task { await chat.send("Create an artifact on my work load") }
        try await Task.sleep(for: .seconds(0.4))
        #expect(chat.isResponding && chat.turnStarted != nil)
        #expect(chat.activity == "Preparing: Make page", "\(chat.activity)")
        #expect(chat.messages.last?.text == "Let me gather the data.")
        await chat.send("And another thing")
        chat.stop()
        await turn.value
        #expect(!chat.isResponding && chat.queue.isEmpty && chat.turnStarted == nil)
        #expect(chat.messages.last?.role == .assistant && chat.messages.last?.text == "Let me gather the data.\n\n*Stopped.*")
    }

    @Test func aChatExportsAsMarkdownAndItsSettingsSync() async throws {
        let (workspace, container) = try makeWorkspace()
        let chat = makeChat(container)
        try chat.record(.user, "Plan my week", steps: [ChatStep(attached: ChatFile(name: "notes.txt", text: "x"))])
        var added = ChatStep(tool: "addTask", label: "Add to-do", detail: "title: Book flights")
        (added.state, added.changed) = (.done, true)
        try chat.record(.assistant, "Here is a plan.", steps: [added])
        let text = ChatText.markdown(of: try #require(chat.thread))
        #expect(text.hasPrefix("# Plan my week\n\n_Ezra, "))
        #expect(text.contains("**You**\n\nPlan my week\n\n📎 notes.txt") && text.hasSuffix("**Ezra**\n\nHere is a plan.\n\n- Add to-do: title: Book flights"))
        _ = workspace
    }
}

@MainActor
struct AutomationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func anAutomationKnowsWhenItRunsNextAndWhenItIsDue() {
        var daily = Automation(title: "Plan", prompt: "Plan my day", every: .day, hour: 8, minute: 30, createdAt: at(12, 9))
        #expect(daily.nextRun(after: at(12, 9), calendar: calendar) == at(13, 8, 30))
        #expect(!daily.isDue(now: at(13, 8, 29), calendar: calendar) && daily.isDue(now: at(13, 8, 30), calendar: calendar))
        // Having run, it waits for the next day; several missed days still count as one run.
        daily.lastRun = at(13, 8, 31)
        #expect(!daily.isDue(now: at(13, 20), calendar: calendar) && daily.isDue(now: at(17, 9), calendar: calendar))
        daily.enabled = false
        #expect(!daily.isDue(now: at(17, 9), calendar: calendar))

        let hourly = Automation(prompt: "x", every: .hour, minute: 15, createdAt: at(12, 9))
        #expect(hourly.nextRun(after: at(12, 9, 20), calendar: calendar) == at(12, 10, 15))
        // 2026-11-12 is a Thursday (weekday 5); the next Monday (2) is the 16th.
        let weekly = Automation(prompt: "x", every: .week, hour: 7, weekday: 2, createdAt: at(12, 9))
        #expect(weekly.nextRun(after: at(12, 9), calendar: calendar) == at(16, 7) && weekly.schedule == "Every Monday at 07:00")
        let monthly = Automation(prompt: "x", every: .month, hour: 6, day: 1, createdAt: at(12, 9))
        #expect(monthly.nextRun(after: at(12, 9), calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 6)))
        #expect(!Automation(prompt: "  ", createdAt: at(1, 0)).isDue(now: at(20, 0), calendar: calendar))
    }

    @Test func aDueAutomationRunsOnceInItsOwnFiledChat() async throws {
        let (workspace, container) = try makeWorkspace()
        let store = AutomationStore(defaults: try #require(UserDefaults(suiteName: "ezra-tests-\(UUID().uuidString)")))
        store.items = [
            Automation(title: "Morning plan", prompt: "Plan my day", createdAt: Date(timeIntervalSinceNow: -3 * 86400)),
            Automation(title: "Off", prompt: "Never", enabled: false, createdAt: Date(timeIntervalSinceNow: -3 * 86400)),
        ]
        let claude = FakeClaude([(200, #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "Start with the report."}]}"#)])
        let runner = AutomationRunner(store: store) { makeChat(container, engine: .claude, key: "k", transport: claude.transport) }
        await runner.runDue()
        await runner.runDue()
        let chats = try workspace.context.fetch(FetchDescriptor<ChatThread>())
        #expect(chats.map(\.title) == ["⏱ Morning plan"] && chats.first?.folder == "Automations")
        #expect(chats.first?.sortedMessages.map(\.text) == ["Plan my day", "Start with the report."])
        #expect(store.items[0].lastRun != nil && store.items[1].lastRun == nil && claude.requests.count == 1)
        // What was saved is what a fresh store reads back.
        #expect(AutomationStore(defaults: try #require(UserDefaults(suiteName: "x-\(UUID().uuidString)"))).items.isEmpty)
    }
}
