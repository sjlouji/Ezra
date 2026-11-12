import Foundation
import SwiftData

/// A large made-up data set, for seeing how the app holds up. It lives in a store of its own and is never synced.
/// Launch with `-LoadTest 5000` (the number of to-dos) to open the app on it.
@MainActor
enum LoadTest {
    static let storeName = "load-test"
    /// How many to-dos the running app was asked to generate; 0 in normal use.
    static var active = 0

    static var requested: Int { max(UserDefaults.standard.integer(forKey: "LoadTest"), 0) }

    /// The same numbers every run, so two measurements are of the same data.
    private struct Dice {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func roll(_ below: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(below, 1)))
        }
        mutating func chance(_ percent: Int) -> Bool { roll(100) < percent }
    }

    private static let verbs = ["Review", "Draft", "Send", "Book", "Call", "Fix", "Plan", "Order", "Update", "Research", "Schedule", "Prepare", "Write", "Check", "File"]
    private static let things = ["the report", "invoices", "the contract", "flights", "the budget", "release notes", "the backlog", "the slides", "suppliers",
                                 "the roadmap", "tax forms", "the newsletter", "onboarding", "the migration", "user interviews", "the estimate"]
    private static let tags = ["Admin", "Errand", "Home", "Important", "Work", "Writing", "Finance", "Health", "Waiting", "Quick", "Deep work", "Family"]

    /// Fills an empty store. Everything is inserted in one go and saved once.
    @discardableResult
    static func fill(_ context: ModelContext, todos count: Int, now: Date = .now) throws -> (todos: Int, projects: Int, notes: Int, events: Int, chats: Int) {
        var dice = Dice()
        let areas = ["Work", "Home", "Family", "Money", "Health", "Side Projects", "Learning", "Travel"].enumerated().map { index, name in
            let area = Area(name: name)
            area.order = Double(index)
            context.insert(area)
            return area
        }
        var projects: [Project] = []
        for index in 0..<max(10, count / 40) {
            let project = Project(name: "\(verbs[dice.roll(verbs.count)]) \(things[dice.roll(things.count)]) \(index + 1)")
            (project.order, project.details) = (Double(index), "Generated for load testing.")
            context.insert(project)
            if !dice.chance(12) { project.area = areas[dice.roll(areas.count)] }
            if dice.chance(8) { project.completedAt = SmartList.day(-dice.roll(90), from: now) }
            for title in ["Planning", "Doing", "Wrap-up"].prefix(dice.roll(4)) {
                let heading = Heading(title: title)
                heading.order = Double(dice.roll(1000))
                context.insert(heading)
                heading.project = project
            }
            projects.append(project)
        }
        for index in 0..<count {
            let todo = ToDo(title: "\(verbs[dice.roll(verbs.count)]) \(things[dice.roll(things.count)]) #\(index + 1)")
            todo.order = Double(index)
            if dice.chance(30) { todo.notes = "Context for this to-do. See [[Note \(dice.roll(max(count / 25, 1)) + 1)]] for the details." }
            todo.tags = Workspace.tidied((0..<dice.roll(3)).map { _ in tags[dice.roll(tags.count)] })
            context.insert(todo)
            if dice.chance(80) {
                let project = projects[dice.roll(projects.count)]
                todo.project = project
                if dice.chance(40) { todo.heading = (project.headings ?? []).first }
            } else if dice.chance(50) {
                todo.area = areas[dice.roll(areas.count)]
            }
            switch dice.roll(100) {
            case ..<45: (todo.when, todo.completedAt) = (.anytime, now.addingTimeInterval(-Double(dice.roll(120 * 86400))))
            case ..<52: todo.when = todo.project == nil && todo.area == nil ? .inbox : .anytime
            case ..<70: todo.when = .anytime
            case ..<77: todo.when = .someday
            case ..<84: (todo.when, todo.startDate, todo.evening) = (.dated, SmartList.day(-dice.roll(3), from: now), dice.chance(25))
            default: (todo.when, todo.startDate) = (.dated, SmartList.day(1 + dice.roll(60), from: now))
            }
            if dice.chance(20) { todo.deadline = SmartList.day(dice.roll(45) - 5, from: now) }
            if dice.chance(10) {
                for step in 1...3 {
                    let item = ChecklistItem(title: "Step \(step)")
                    item.createdAt = now.addingTimeInterval(Double(step))
                    context.insert(item)
                    item.task = todo
                }
            }
        }
        let noteCount = max(count / 25, 1)
        for index in 0..<noteCount {
            let note = Note(title: "Note \(index + 1)", body: String(repeating: "## Section\nSome longer text about \(things[dice.roll(things.count)]). See [[Note \(dice.roll(noteCount) + 1)]].\n- a point\n- another point\n\n", count: 6 + dice.roll(14)))
            (note.order, note.updatedAt) = (Double(index), now.addingTimeInterval(-Double(dice.roll(60 * 86400))))
            context.insert(note)
            if dice.chance(50) { note.project = projects[dice.roll(projects.count)] }
        }
        let eventCount = max(count / 20, 1)
        for index in 0..<eventCount {
            let start = SmartList.day(dice.roll(60) - 30, from: now).addingTimeInterval(Double(7 + dice.roll(12)) * 3600)
            context.insert(PlannerEvent(title: "Meeting \(index + 1)", start: start, end: start.addingTimeInterval(3600)))
        }
        for index in 0..<40 {
            let thread = ChatThread(title: "Chat about \(things[dice.roll(things.count)]) \(index + 1)")
            thread.updatedAt = now.addingTimeInterval(-Double(index) * 7200)
            context.insert(thread)
            for turn in 0..<6 {
                let message = ChatMessage(roleRaw: turn.isMultiple(of: 2) ? "user" : "assistant", text: "Message \(turn + 1) about \(things[dice.roll(things.count)]). " + String(repeating: "More words. ", count: 20))
                message.createdAt = thread.updatedAt.addingTimeInterval(Double(turn))
                context.insert(message)
                message.thread = thread
            }
        }
        try context.save()
        return (count, projects.count, noteCount, eventCount, 40)
    }

    /// Removes the load-test store's files, so each run starts from the same data.
    static func removeStore() throws {
        let folder = URL.applicationSupportDirectory
        for suffix in ["", "-shm", "-wal"] {
            let file = folder.appending(path: "\(storeName).store\(suffix)")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
