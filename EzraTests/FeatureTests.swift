import Foundation
import SwiftData
import Testing

@testable import Ezra

/// Noon on Thursday 12 November 2026.
private let calendar = Calendar.current
private let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
private func day(_ offset: Int) -> Date { SmartList.day(offset, from: noon, calendar: calendar) }
private func date(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

struct WhenPhraseTests {
    private let us = Locale(identifier: "en_US")
    private func first(_ text: String, locale: Locale = Locale(identifier: "en_US")) -> WhenSuggestion? {
        WhenPhrase.suggestions(for: text, now: noon, calendar: calendar, locale: locale).first
    }

    @Test func offsetsFromToday() {
        #expect(first("17d")?.date == day(17))
        #expect(first("2w")?.date == day(14))
        #expect(first("3mo")?.date == date(2027, 2, 12))
        #expect(first("1y")?.date == date(2027, 11, 12))
        #expect(first("in 10 days")?.date == day(10))
        #expect(first("next month")?.date == date(2026, 12, 1))
    }

    @Test func namedAndNumericDatesTakeTheirNextOccurrence() {
        #expect(first("jul 9")?.date == date(2027, 7, 9))
        #expect(first("9 jul")?.date == date(2027, 7, 9))
        #expect(first("jul9")?.date == date(2027, 7, 9))
        #expect(first("dec 1")?.date == date(2026, 12, 1))
        #expect(first("jul 9 2028")?.date == date(2028, 7, 9))
        #expect(first("10-3")?.date == date(2027, 10, 3))
        #expect(first("10-3", locale: Locale(identifier: "en_GB"))?.date == date(2027, 3, 10))
        #expect(first("feb 30") == nil)
    }

    @Test func weekdaysWithinAMonth() {
        #expect(first("wed jul")?.date == date(2027, 7, 7))
        #expect(first("3rd wed jul")?.date == date(2027, 7, 21))
        #expect(first("last fri jul")?.date == date(2027, 7, 30))
        #expect(first("3rd wed jul 2028")?.date == date(2028, 7, 19))
    }

    @Test func aTrailingTimeBecomesAReminder() {
        let tomorrow = first("tom 2p")
        #expect(tomorrow?.date == day(1) && tomorrow?.reminderMinutes == 14 * 60)
        #expect(tomorrow?.reminderDate == day(1).addingTimeInterval(14 * 3600))
        #expect(first("2p")?.date == day(0) && first("2p")?.reminderMinutes == 840)
        #expect(first("fri at 9:30am")?.reminderMinutes == 9 * 60 + 30)
        #expect(first("14:45")?.reminderMinutes == 14 * 60 + 45)
        let numeric = first("10-3 9")
        #expect(numeric?.date == date(2027, 10, 3) && numeric?.reminderMinutes == 9 * 60)
        // A number that is part of the date is not a time.
        #expect(first("jul 9")?.reminderMinutes == nil && first("in 3")?.reminderMinutes == nil)
        #expect(first("12am")?.reminderMinutes == 0 && first("12pm")?.reminderMinutes == 720)
        #expect(first("25:00") == nil && first("9") == nil)
    }
}

@MainActor
struct RepeatTests {
    @Test func aScheduledRepeatKeepsOneCopyForTodayAndOneComing() throws {
        let (workspace, _) = try makeWorkspace()
        let todo = try workspace.addToDo(title: "Water plants", schedule: .on(.now), tags: ["Home"])
        let item = ChecklistItem(title: "Balcony")
        workspace.context.insert(item)
        item.task = todo
        try workspace.setRepeat(todo, RepeatRule(mode: .schedule, every: 1, unit: .week))

        #expect(todo.isTemplate && !SmartList.today.contains(todo) && !SmartList.anytime.contains(todo))
        let today = try workspace.tasks(in: .today)
        #expect(today.map(\.title) == ["Water plants"] && today.first?.templateUUID == todo.uuid)
        #expect(today.first?.tags == ["Home"] && today.first?.sortedChecklist.map(\.title) == ["Balcony"])
        #expect(try workspace.tasks(in: .upcoming).map(\.startDate) == [SmartList.day(7)])

        try workspace.generateRepeats()
        #expect(try workspace.allToDos().count == 3) // the template and its two copies: nothing is made twice

        // A week on, the coming copy has become today's and a new one is lined up.
        try workspace.generateRepeats(now: SmartList.day(7).addingTimeInterval(3600))
        #expect(Set(try workspace.allToDos().compactMap { $0.templateUUID == nil ? nil : $0.startDate }) == [SmartList.day(0), SmartList.day(7), SmartList.day(14)])

        // After a month away, only the latest missed occurrence is added, not one for every week.
        try workspace.generateRepeats(now: SmartList.day(36))
        let days = Set(try workspace.allToDos().compactMap { $0.templateUUID == nil ? nil : $0.startDate })
        #expect(days == [SmartList.day(0), SmartList.day(7), SmartList.day(14), SmartList.day(35), SmartList.day(42)])
    }

    @Test func anAfterCompletionRepeatWaitsForTheCopyToBeDone() throws {
        let (workspace, _) = try makeWorkspace()
        let todo = try workspace.addToDo(title: "Back up laptop")
        try workspace.setRepeat(todo, RepeatRule(mode: .afterCompletion, every: 3, unit: .day))
        let first = try #require(try workspace.tasks(in: .today).first)
        try workspace.generateRepeats(now: SmartList.day(10))
        #expect(try workspace.allToDos().count == 2) // still waiting on the first copy

        try workspace.setCompleted(first, true)
        #expect(try workspace.tasks(in: .upcoming).map(\.startDate) == [SmartList.day(3)])
    }

    @Test func pausingStopsCopiesAndStoppingMakesItAnOrdinaryToDoAgain() throws {
        let (workspace, _) = try makeWorkspace()
        let todo = try workspace.addToDo(title: "Review budget", schedule: .on(.now))
        try workspace.setRepeat(todo, RepeatRule(mode: .schedule, every: 1, unit: .month, isPaused: true))
        #expect(try workspace.allToDos().count == 1 && todo.repeatRule?.summary == "Every month (paused)")
        try workspace.setRepeat(todo, nil)
        #expect(!todo.isTemplate && SmartList.today.contains(todo))
    }

    @Test func aRepeatingProjectMakesFreshCopiesAndItsTemplateStaysOutOfTheLists() throws {
        let (workspace, _) = try makeWorkspace()
        let template = try workspace.addProject(name: "Monthly close")
        let heading = try workspace.addHeading(title: "Books", to: template)
        let task = try workspace.addToDo(title: "Reconcile accounts", project: template, heading: heading)
        try workspace.setRepeat(template, RepeatRule(mode: .schedule, every: 1, unit: .month))

        #expect(template.isTemplate && !SmartList.anytime.contains(task))
        let copy = try #require(try workspace.projects().first { $0.templateUUID == template.uuid })
        #expect(copy.name == "Monthly close" && copy.sortedHeadings.map(\.title) == ["Books"])
        #expect(copy.openTasks.map(\.title) == ["Reconcile accounts"] && copy.openTasks.first?.heading?.project == copy)
        #expect(SmartList.anytime.contains(try #require(copy.openTasks.first)))
        try workspace.generateRepeats()
        #expect(try workspace.projects().count == 2)
        #expect(template.repeatRule?.next == calendar.date(byAdding: .month, value: 1, to: calendar.startOfDay(for: .now)))
    }
}

@MainActor
struct AddCommandTests {
    @Test func aLinkCarriesEveryField() throws {
        let url = try #require(URL(string: "ezra:///add?title=Call%20Sam&notes=About%20the%20launch&when=tom%202pm&deadline=dec%201&tags=Work,%20Calls&checklist-items=Agenda%0AMinutes&list=Launch&heading=Prep"))
        var expected = AddCommand(title: "Call Sam")
        (expected.notes, expected.when, expected.deadline) = ("About the launch", "tom 2pm", "dec 1")
        (expected.tags, expected.checklist, expected.list, expected.heading) = (["Work", "Calls"], ["Agenda", "Minutes"], "Launch", "Prep")
        #expect(AddCommand(url: url) == expected)
        #expect(AddCommand(url: try #require(URL(string: "ezra://add?title=Short"))) == AddCommand(title: "Short"))
        #expect(AddCommand(url: try #require(URL(string: "ezra:///delete?title=No"))) == nil)
        #expect(AddCommand(url: try #require(URL(string: "https://example.com/add?title=No"))) == nil)
    }

    @Test func theCommandCreatesTheToDoWhereItSays() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        let heading = try workspace.addHeading(title: "Prep", to: project)
        var command = AddCommand(title: "Call Sam")
        (command.when, command.deadline, command.tags) = ("tom 2pm", "dec 1", ["Work"])
        (command.checklist, command.list, command.heading) = (["Agenda"], "launch", "prep")

        let todo = try command.run(in: workspace, now: noon)
        #expect(todo.project == project && todo.heading == heading && todo.tags == ["Work"])
        #expect(todo.startDate == day(1) && todo.reminderAt == day(1).addingTimeInterval(14 * 3600))
        #expect(todo.deadline == date(2026, 12, 1) && todo.sortedChecklist.map(\.title) == ["Agenda"])

        var someday = AddCommand(title: "Learn guitar")
        someday.list = "Someday"
        #expect(try someday.run(in: workspace, now: noon).when == .someday)
        #expect(try AddCommand(title: "Loose").run(in: workspace, now: noon).when == .inbox)
    }

    @Test func aCommandThatCannotBeUnderstoodCreatesNothing() throws {
        let (workspace, _) = try makeWorkspace()
        var command = AddCommand(title: "X")
        command.when = "whenever"
        #expect(throws: WorkspaceError.badDate("whenever")) { try command.run(in: workspace, now: noon) }
        command.when = nil
        command.list = "No such project"
        #expect(throws: WorkspaceError.self) { try command.run(in: workspace, now: noon) }
        #expect(throws: WorkspaceError.emptyName(kind: "task")) { try AddCommand(title: " ").run(in: workspace, now: noon) }
        #expect(try workspace.allToDos().isEmpty)
    }

    @Test func theMovePanelCanSendAToDoToAHeadingOrOutOfItsProject() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        let heading = try workspace.addHeading(title: "Prep", to: project)
        let todo = try workspace.addToDo(title: "Loose")
        let app = AppModel()
        app.context = workspace.context

        app.drop(.todo(todo), on: .heading(heading))
        #expect(todo.project == project && todo.heading == heading && todo.when == .anytime)
        app.drop(.todo(todo), on: .detached)
        #expect(todo.project == nil && todo.heading == nil && todo.when == .anytime)
    }
}
