import Foundation
import SwiftData
import Testing
@testable import Ezra

/// The database's version of each list must hold exactly the to-dos the in-memory rule (`SmartList.contains`) does.
@MainActor
struct ListQueryTests {
    private let now = Date.now

    /// Every combination that the rules tell apart: each plan, with and without a start date and a deadline on either side
    /// of today, open and completed, a template or not, loose or inside an ordinary, repeating or blueprint project.
    private func fill(_ context: ModelContext) throws -> [ToDo] {
        let day: TimeInterval = 86_400
        let dates: [Date?] = [nil, now.addingTimeInterval(-3 * day), now, now.addingTimeInterval(3 * day)]
        let plain = Project(name: "Plain"), repeating = Project(name: "Repeating"), blueprint = Project(name: "Blueprint")
        repeating.repeatRuleData = Data([1])
        blueprint.isBlueprint = true
        [plain, repeating, blueprint].forEach(context.insert)
        var number = 0
        for when in [When.inbox, .anytime, .dated, .someday] {
            for start in dates {
                for deadline in dates {
                    for completed in [false, true] {
                        for template in [false, true] {
                            for project in [nil, plain, repeating, blueprint] {
                                number += 1
                                let todo = ToDo(title: "To-do \(number)")
                                (todo.whenRaw, todo.startDate, todo.deadline) = (when.rawValue, start, deadline)
                                // Distinct completion times, so the Logbook's order is fully decided.
                                todo.completedAt = completed ? now.addingTimeInterval(-Double(number) * 60) : nil
                                todo.repeatRuleData = template ? Data([1]) : nil
                                todo.project = project
                                context.insert(todo)
                            }
                        }
                    }
                }
            }
        }
        try context.save()
        return try context.fetch(FetchDescriptor<ToDo>())
    }

    private func titles(_ todos: [ToDo]) -> Set<String> { Set(todos.map(\.title)) }

    @Test func theDatabaseListsHoldWhatTheRulesSay() throws {
        let (workspace, _) = try makeWorkspace()
        let context = workspace.context
        let all = try fill(context)
        #expect(all.count == 4 * 4 * 4 * 2 * 2 * 4)

        let cases: [(SmartList, Predicate<ToDo>)] = [
            (.inbox, ListQuery.inbox()), (.today, ListQuery.today(now: now)), (.logbook, ListQuery.logbook()),
        ]
        for (list, query) in cases {
            let wanted = titles(all.filter { list.contains($0, now: now) })
            let found = try context.fetch(FetchDescriptor(predicate: query))
            #expect(!wanted.isEmpty)
            #expect(titles(found) == wanted, "\(list.rawValue)")
            #expect(try context.fetchCount(FetchDescriptor(predicate: query)) == wanted.count, "\(list.rawValue) count")
        }

        let overdue = titles(all.filter { !$0.isCompleted && !$0.isTemplate && ($0.daysToDeadline(now: now) ?? 1) <= 0 })
        #expect(titles(try context.fetch(FetchDescriptor(predicate: ListQuery.due(now: now)))) == overdue)
    }

    @Test func theLibraryCountsFromTheDatabaseAndPagesTheLogbook() throws {
        let (workspace, _) = try makeWorkspace()
        let all = try fill(workspace.context)
        let library = Library(context: workspace.context)
        library.refresh(now: now)
        #expect(library.inbox == all.count { SmartList.inbox.contains($0, now: now) })
        #expect(library.today == all.count { SmartList.today.contains($0, now: now) })

        let logged = all.filter { SmartList.logbook.contains($0, now: now) }.sorted { $0.completedAt! > $1.completedAt! }
        #expect(try library.completedCount() == logged.count)
        // A page is the newest ones, newest first; a longer page starts with the shorter one.
        let first = try library.completed(limit: 25)
        #expect(first.map(\.title) == logged.prefix(25).map(\.title))
        #expect(try library.completed(limit: 60).prefix(25).map(\.title) == first.map(\.title))
        #expect(try library.completed(limit: 10_000).count == logged.count)

        // A save is noticed: the revision moves and the newly completed to-do leads the next page.
        let before = library.revision
        let fresh = try workspace.addToDo(title: "Just done")
        try workspace.setCompleted(fresh, true)
        library.refresh()
        #expect(library.revision > before)
        #expect(try library.completed(limit: 1).first?.title == "Just done")
    }

    @Test func clearingTheLogbookRemovesOnlyCompletedToDos() throws {
        let (workspace, _) = try makeWorkspace()
        let all = try fill(workspace.context)
        let open = all.count { !$0.isCompleted }
        try workspace.clearLogbook()
        #expect(try workspace.allToDos().count == open)
    }
}
