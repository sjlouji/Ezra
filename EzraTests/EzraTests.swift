import Foundation
import SwiftData
import Testing

@testable import Ezra

/// A ModelContext does not keep its container alive, and using one after its container is gone crashes.
/// The app holds its container for its whole life; tests do the same here.
@MainActor var liveContainers: [ModelContainer] = []

@MainActor
func makeWorkspace() throws -> (Workspace, ModelContainer) {
    let container = try EzraStore.makeContainer(inMemory: true)
    liveContainers.append(container)
    return (Workspace(context: container.mainContext, reminders: nil), container)
}

private let calendar = Calendar.current
private let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: noon))!
}

@MainActor
struct SmartListTests {
    private func lists(_ task: ToDo) -> Set<SmartList> {
        Set(SmartList.allCases.filter { $0.contains(task, now: noon, calendar: calendar) })
    }

    @Test func unfiledUnscheduledTaskIsOnlyInInbox() throws {
        let (workspace, _) = try makeWorkspace()
        #expect(lists(try workspace.addToDo(title: "Loose")) == [.inbox])
    }

    @Test func taskStartingTodayOrEarlierIsInToday() throws {
        let (workspace, _) = try makeWorkspace()
        #expect(lists(try workspace.addToDo(title: "Now", schedule: .on(noon))) == [.today, .anytime])
        #expect(lists(try workspace.addToDo(title: "Late", schedule: .on(day(-3)))) == [.today, .anytime])
    }

    @Test func overdueDeadlinePutsAnInboxTaskInTodayToo() throws {
        let (workspace, _) = try makeWorkspace()
        #expect(lists(try workspace.addToDo(title: "Due", deadline: day(-1))) == [.inbox, .today])
    }

    @Test func futureTaskIsOnlyInUpcoming() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        #expect(lists(try workspace.addToDo(title: "Later", project: project, schedule: .on(day(1)))) == [.upcoming])
    }

    @Test func projectTaskWithoutDateIsInAnytime() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        #expect(lists(try workspace.addToDo(title: "Whenever", project: project)) == [.anytime])
    }

    @Test func somedayAndCompletedTasksLeaveTheActiveLists() throws {
        let (workspace, _) = try makeWorkspace()
        let someday = try workspace.addToDo(title: "Maybe", schedule: .someday)
        #expect(lists(someday) == [.someday])
        try workspace.setCompleted(someday, true)
        #expect(lists(someday) == [.logbook])
    }
}

@MainActor
struct WorkspaceTests {
    @Test func schedulingNormalisesToStartOfDayAndClearsSomeday() throws {
        let (workspace, _) = try makeWorkspace()
        let task = try workspace.addToDo(title: "Plan", schedule: .someday)
        try workspace.schedule(task, .on(noon))
        #expect(task.startDate == calendar.startOfDay(for: noon))
        #expect(task.when == .dated)
    }

    @Test func emptyTitleIsRejected() throws {
        let (workspace, _) = try makeWorkspace()
        #expect(throws: WorkspaceError.emptyName(kind: "task")) { try workspace.addToDo(title: "   ") }
    }

    @Test func findPrefersExactNameAndReportsAmbiguity() throws {
        let (workspace, _) = try makeWorkspace()
        try workspace.addToDo(title: "Call bank")
        try workspace.addToDo(title: "Call bank about loan")
        #expect(try workspace.findToDo("call bank").title == "Call bank")
        #expect(throws: WorkspaceError.self) { try workspace.findToDo("call") }
        #expect(throws: WorkspaceError.notFound(kind: "open task", query: "dentist")) { try workspace.findToDo("dentist") }
    }

    @Test func completingAProjectCompletesItsOpenTasks() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Move house")
        let task = try workspace.addToDo(title: "Book van", project: project)
        try workspace.setCompleted(project, true)
        #expect(task.isCompleted)
        #expect(project.isCompleted)
    }

    @Test func deletingAProjectDeletesItsTasksAndNotes() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Temp")
        try workspace.addToDo(title: "Inside", project: project)
        try workspace.addNote(title: "Page", project: project)
        try workspace.delete(project)
        #expect(try workspace.tasks().isEmpty)
        #expect(try workspace.notes().isEmpty)
    }

    @Test func typedPhrasesBecomeDays() {
        func labels(_ text: String) -> [String] { WhenPhrase.suggestions(for: text, now: noon, calendar: calendar).map(\.label) }
        #expect(labels("to") == ["Today", "This Evening", "Tomorrow"])
        #expect(WhenPhrase.suggestions(for: "tom", now: noon, calendar: calendar) == [WhenSuggestion(label: "Tomorrow", date: day(1))])
        #expect(WhenPhrase.suggestions(for: "eve", now: noon, calendar: calendar) == [WhenSuggestion(label: "This Evening", date: day(0), evening: true)])
        // Noon is Thursday 12 November 2026, so "fri" is the next day and "th" a week on.
        #expect(WhenPhrase.suggestions(for: "fri", now: noon, calendar: calendar) == [WhenSuggestion(label: "Friday", date: day(1))])
        #expect(WhenPhrase.suggestions(for: "thu", now: noon, calendar: calendar) == [WhenSuggestion(label: "Thursday", date: day(7))])
        #expect(labels("in 3") == ["in 3 days", "in 3 weeks", "in 3 months"])
        #expect(WhenPhrase.suggestions(for: "in 3 w", now: noon, calendar: calendar) == [WhenSuggestion(label: "in 3 weeks", date: day(21))])
        #expect(WhenPhrase.suggestions(for: "2026-11-20", now: noon, calendar: calendar).map(\.date) == [day(8)])
        #expect(WhenPhrase.suggestions(for: "som", now: noon, calendar: calendar) == [WhenSuggestion(label: "Someday", date: nil)])
        #expect(labels("zzz").isEmpty && labels("  ").isEmpty)
    }

    @Test func dayTextParsesWordsAndDates() throws {
        #expect(try DayText.schedule(from: "Someday") == .someday)
        #expect(try DayText.schedule(from: "none") == .unscheduled)
        #expect(try DayText.day(from: "tomorrow", now: noon, calendar: calendar) == day(1))
        #expect(try DayText.day(from: "2026-11-20", calendar: calendar) == day(8))
        #expect(DayText.string(day: day(8), calendar: calendar) == "2026-11-20")
        let moment = try DayText.moment(from: "2026-11-12 12:00", calendar: calendar)
        #expect(moment == noon)
        #expect(throws: WorkspaceError.badDate("next week")) { try DayText.day(from: "next week") }
    }
}

struct NoteMarkdownTests {
    @Test func parsesOneBlockPerLine() {
        let blocks = NoteMarkdown.blocks("# Plan\n\n- [ ] book\n- [x] pay\n- item\n## Sub\ntext")
        #expect(blocks == [
            .heading(level: 1, text: "Plan"), .blank,
            .checkbox(done: false, text: "book"), .checkbox(done: true, text: "pay"),
            .bullet("item"), .heading(level: 2, text: "Sub"), .paragraph("text"),
        ])
    }

    @Test func togglesOnlyTheCheckboxOnThatLine() {
        let source = "- [ ] a\n- [x] b\nplain"
        #expect(NoteMarkdown.togglingCheckbox(atLine: 0, in: source) == "- [x] a\n- [x] b\nplain")
        #expect(NoteMarkdown.togglingCheckbox(atLine: 1, in: source) == "- [ ] a\n- [ ] b\nplain")
        #expect(NoteMarkdown.togglingCheckbox(atLine: 2, in: source) == source)
        #expect(NoteMarkdown.togglingCheckbox(atLine: 9, in: source) == source)
    }
}
