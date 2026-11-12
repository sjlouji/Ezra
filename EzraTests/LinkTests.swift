import Foundation
import SwiftData
import Testing
@testable import Ezra

@MainActor
struct LinkTests {
    @Test func noteLinksAreFoundRenderedAndFollowedBack() throws {
        #expect(NoteLinks.titles(in: "See [[Trip plan]] and [[ Budget ]], again [[trip plan]]. Not [[]] or [single].") == ["Trip plan", "Budget"])
        let rendered = NoteLinks.markdown("Read [[Trip plan / v2]] first")
        #expect(rendered == "Read [Trip plan / v2](ezra-note:Trip%20plan%20%2F%20v2) first")
        #expect(NoteLinks.title(from: try #require(URL(string: "ezra-note:Trip%20plan%20%2F%20v2"))) == "Trip plan / v2")
        #expect(NoteLinks.title(from: try #require(URL(string: "https://example.com"))) == nil)
        // The link reaches the screen as a real link.
        #expect(NoteMarkdown.inline("Read [[Budget]]").runs.contains { $0.link?.scheme == "ezra-note" })

        let (workspace, _) = try makeWorkspace()
        let plan = try workspace.addNote(title: "Trip plan", project: try workspace.addProject(name: "Rome"))
        let diary = try workspace.addNote(title: "Diary", body: "Wrote the [[trip plan]] today.")
        try workspace.addNote(title: "Unrelated", body: "Nothing here.")
        let mention = try workspace.addToDo(title: "Book hotel", notes: "As in [[Trip plan]]")
        try workspace.setCompleted(mention, true)
        let made = try workspace.addToDo(for: plan, title: "Print tickets")

        #expect(try workspace.backlinks(to: plan) == [diary])
        #expect(try workspace.todos(linking: plan).map(\.title) == ["Print tickets", "Book hotel"])
        #expect(made.project?.name == "Rome" && made.notes == "[[Trip plan]]")
        #expect(try workspace.note(titled: " trip PLAN ") == plan)
    }

    @Test func theAssistantRemembersInANoteAndIsToldWhatItKnows() async throws {
        let (workspace, container) = try makeWorkspace()
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        _ = box.run("remember", ToolInput(value: .object(["fact": .string("Plans the week on Sundays")])))
        _ = box.run("remember", ToolInput(value: .object(["fact": .string("Plans the week on Sundays")])))
        try workspace.remember("Wife is called Eve")
        let memory = try #require(try workspace.note(titled: Workspace.memoryTitle))
        #expect(memory.body == "- Plans the week on Sundays\n- Wife is called Eve")
        // The user can edit the note; what is there is what is remembered.
        memory.body += "\nprefers mornings"
        #expect(try workspace.memories() == ["Plans the week on Sundays", "Wife is called Eve", "prefers mornings"])

        let claude = FakeClaude([(200, #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "Hi"}]}"#)])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        await chat.send("Hello")
        let system = try #require(try claude.body(0)["system"]?.text)
        #expect(system.contains("What you remember about the user:\n- Plans the week on Sundays\n- Wife is called Eve\n- prefers mornings"))
    }

    @Test func aPageIsSavedAsANoteWithTheHTMLAttached() throws {
        let (workspace, _) = try makeWorkspace()
        let folder = FileManager.default.temporaryDirectory.appending(path: "pages-\(UUID().uuidString)")
        let store = AttachmentStore(localFolder: folder, restoresChoice: false)
        let note = try workspace.savePage(ChatPage(title: "Budget / chart", html: "<p>Hi</p>"), store: store)
        let attachment = try #require(note.sortedAttachments.first)
        #expect(note.title == "Budget / chart" && attachment.filename == "Budget - chart.html")
        let saved = try String(contentsOf: store.url(for: attachment), encoding: .utf8)
        #expect(saved.contains("<p>Hi</p>") && saved.contains("Content-Security-Policy"))
    }

    @Test func theBriefingCountsTheDayWhatIsLateAndWhatSlipped() throws {
        let (workspace, _) = try makeWorkspace()
        let calendar = Calendar.current
        let nine = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now))
        try workspace.addToDo(title: "Write report", schedule: .on(nine), deadline: nine)
        try workspace.addToDo(title: "Call bank", schedule: .on(SmartList.day(-2, from: nine)))
        try workspace.addToDo(title: "File taxes", deadline: SmartList.day(-1, from: nine))
        try workspace.addToDo(title: "Someday thing", schedule: .someday)
        let done = try workspace.addToDo(title: "Done", schedule: .on(nine))
        try workspace.setCompleted(done, true)
        let events = [
            DayEvent(id: "a", title: "Stand-up", start: nine.addingTimeInterval(-3600), end: nine, isAllDay: false, tint: .red),
            DayEvent(id: "b", title: "Team meeting", start: nine.addingTimeInterval(7200), end: nine.addingTimeInterval(10800), isAllDay: false, tint: .red),
            DayEvent(id: "c", title: "Birthday", start: calendar.startOfDay(for: nine), end: nine, isAllDay: true, tint: .red),
        ]
        let briefing = DailyBriefing.make(todos: try workspace.allToDos(), events: events, now: nine)
        #expect(briefing.planned == 3 && briefing.carriedOver == 1 && briefing.dueToday == 1)
        #expect(briefing.overdue == ["File taxes"] && briefing.events == 3)
        #expect(briefing.nextEvent?.hasSuffix("Team meeting") == true)
        #expect(briefing.lines.prefix(3) == ["3 to-dos today, 1 due today.", "1 overdue: File taxes.", "1 carried over from earlier days."])
        #expect(DailyBriefing().lines == ["Nothing is planned for today."])
    }
}

@MainActor
struct WidgetFeedTests {
    @Test func theWidgetsGetTodayAndTheComingDaysSoonestFirst() throws {
        let (workspace, _) = try makeWorkspace()
        let trip = try workspace.addProject(name: "Trip")
        try workspace.addToDo(title: "Pack", project: trip, schedule: .on(.now), deadline: .now)
        try workspace.addToDo(title: "Later", schedule: .on(SmartList.day(3)))
        try workspace.addToDo(title: "Sooner", schedule: .on(SmartList.day(1)))
        try workspace.addToDo(title: "No date")
        try workspace.setCompleted(try workspace.addToDo(title: "Done", schedule: .on(.now)), true)
        let snapshot = WidgetFeed.snapshot(todos: try workspace.allToDos())
        #expect(snapshot.today.map(\.title) == ["Pack"] && snapshot.today.first?.place == "Trip" && snapshot.today.first?.isDue == true)
        #expect(snapshot.upcoming.map(\.title) == ["Sooner", "Later"] && snapshot.upcoming.first?.day == SmartList.day(1))
        // It survives the trip to the file the widgets read.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(WidgetSnapshot.self, from: try encoder.encode(snapshot))
        #expect(back.today == snapshot.today && back.upcoming.map(\.title) == ["Sooner", "Later"])
    }
}
