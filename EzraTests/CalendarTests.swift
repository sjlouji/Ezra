import Foundation
import Testing
@testable import Ezra

@MainActor
struct CalendarTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 1 // Sunday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func aMonthGridIsSixWholeWeeksAroundTheMonth() {
        let grid = Planner.monthGrid(for: date(2026, 11, 12), calendar: calendar)
        #expect(grid.count == 42)
        // November 2026 starts on a Sunday; the grid runs into December.
        #expect(grid.first == date(2026, 11, 1) && grid.last == date(2026, 12, 12))
        let february = Planner.monthGrid(for: date(2027, 2, 20), calendar: calendar)
        #expect(february.first == date(2027, 1, 31) && february[1] == date(2027, 2, 1))
    }

    @Test func movingByMonthsAndYearsKeepsTheDayWhereItExists() {
        #expect(Planner.shifted(date(2026, 11, 12), by: 1, .month, calendar: calendar) == date(2026, 12, 12))
        #expect(Planner.shifted(date(2026, 11, 12), by: -11, .month, calendar: calendar) == date(2025, 12, 12))
        #expect(Planner.shifted(date(2027, 1, 31), by: 1, .month, calendar: calendar) == date(2027, 2, 28))
        #expect(Planner.shifted(date(2028, 2, 29), by: 1, .year, calendar: calendar) == date(2029, 2, 28))
        let months = Planner.months(ofYearContaining: date(2026, 11, 12), calendar: calendar)
        #expect(months.count == 12 && months.first == date(2026, 1, 1) && months.last == date(2026, 12, 1))
    }

    @Test func droppingAToDoOnAnHourBlocksThatTime() throws {
        let (workspace, _) = try makeWorkspace()
        let todo = try workspace.addToDo(title: "Write report")
        let slot = SmartList.day(2).addingTimeInterval(14 * 3600)
        #expect(DragItem.todo(todo).hint(for: .hour(slot)) == "\(slot.formatted(.dateTime.weekday(.abbreviated))) at \(slot.formatted(date: .omitted, time: .shortened))")
        try workspace.place(todo, at: .hour(slot), plannerDay: .now)
        #expect(todo.when == .dated && todo.startDate == SmartList.day(2) && todo.reminderAt == slot)
        #expect(Planner.week(containing: date(2026, 11, 12), calendar: calendar) == (8...14).map { date(2026, 11, $0) })
        // A week view steps by weeks.
        #expect(Planner.shifted(date(2026, 11, 12), by: 1, .weekOfYear, calendar: calendar) == date(2026, 11, 19))
    }

    @Test func aDaysLoadCountsPlannedAndDueToDosAndEventsOnce() throws {
        let (workspace, _) = try makeWorkspace()
        let day = Calendar.current.startOfDay(for: .now)
        let tomorrow = SmartList.day(1)
        try workspace.addToDo(title: "Planned and due the same day", schedule: .on(day), deadline: day)
        try workspace.addToDo(title: "Planned today, due tomorrow", schedule: .on(day), deadline: tomorrow)
        try workspace.addToDo(title: "No date")
        let done = try workspace.addToDo(title: "Done", schedule: .on(day))
        try workspace.setCompleted(done, true)
        try workspace.addEvent(title: "Call", start: tomorrow.addingTimeInterval(9 * 3600))
        let load = Planner.load(todos: try workspace.allToDos(), events: try workspace.events())
        #expect(load == [day: 2, tomorrow: 2])
    }
}

@MainActor
struct RepeatRuleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    @Test func aWeeklyRuleOnChosenWeekdaysVisitsEachAndSkipsWeeks() {
        // 2026-11-09 is a Monday. Monday (2) and Thursday (5), every week.
        var rule = RepeatRule(every: 1, unit: .week, weekdays: [2, 5])
        #expect(rule.advanced(date(11, 9), calendar: calendar) == date(11, 12))
        #expect(rule.advanced(date(11, 12), calendar: calendar) == date(11, 16))
        #expect(rule.aligned(date(11, 10), calendar: calendar) == date(11, 12))
        #expect(rule.aligned(date(11, 12), calendar: calendar) == date(11, 12))
        #expect(rule.summary == "Every week on Mon, Thu")
        // Every second week: after Thursday comes the Monday two weeks on, not next week's.
        rule.every = 2
        #expect(rule.advanced(date(11, 9), calendar: calendar) == date(11, 12))
        #expect(rule.advanced(date(11, 12), calendar: calendar) == date(11, 23))
        // Weekdays only steer weekly schedules.
        rule.unit = .month
        #expect(rule.advanced(date(11, 9), calendar: calendar) == calendar.date(from: DateComponents(year: 2027, month: 1, day: 9)))
        // Rules saved before these options existed still read.
        let old = try? JSONDecoder().decode(RepeatRule.self, from: Data(#"{"mode":"schedule","every":1,"unit":"week","isPaused":false}"#.utf8))
        #expect(old?.weekdays == nil && old?.deadlineAfter == nil)
    }

    @Test func copiesOfARepeatingToDoCarryItsDeadline() throws {
        let (workspace, _) = try makeWorkspace()
        let today = Calendar.current.startOfDay(for: .now)
        let todo = try workspace.addToDo(title: "Send the report", schedule: .on(today))
        try workspace.setRepeat(todo, RepeatRule(every: 1, unit: .day, deadlineAfter: 2))
        let copies = try workspace.allToDos().filter { $0.templateUUID == todo.uuid }.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        #expect(copies.map(\.startDate) == [today, SmartList.day(1)])
        #expect(copies.map(\.deadline) == [SmartList.day(2), SmartList.day(3)])
    }

    @Test func aProjectSavedAsATemplateCanBeStampedOutAgain() throws {
        let (workspace, _) = try makeWorkspace()
        let trip = try workspace.addProject(name: "Trip", area: try workspace.addArea(name: "Family"))
        let before = try workspace.addHeading(title: "Before", to: trip)
        let pack = try workspace.addToDo(title: "Pack", project: trip, schedule: .on(.now), deadline: .now)
        pack.heading = before
        try workspace.addChecklist(["Passport", "Charger"], to: pack)
        try workspace.setCompleted(try workspace.addToDo(title: "Book flights", project: trip), true)

        let blueprint = try workspace.saveAsTemplate(trip)
        #expect(blueprint.isBlueprint && blueprint.isTemplate && blueprint.name == "Trip")
        // A template is not work: it stays out of the project lists and its to-dos out of every list.
        #expect(try workspace.tasks(in: .anytime).allSatisfy { $0.project == trip })
        #expect(try workspace.tasks().count == 1)

        let rome = try workspace.stampOut(blueprint, name: "Rome")
        #expect(!rome.isBlueprint && rome.templateUUID == nil && rome.area?.name == "Family")
        #expect(rome.sortedHeadings.map(\.title) == ["Before"])
        #expect(rome.openTasks.map(\.title) == ["Pack", "Book flights"])
        let twin = try #require(rome.openTasks.first)
        #expect(twin.heading?.title == "Before" && twin.deadline == nil && twin.startDate == nil)
        #expect(twin.sortedChecklist.map(\.title) == ["Passport", "Charger"])
        #expect(rome.order > trip.order)
    }
}
