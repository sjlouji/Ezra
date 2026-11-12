import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Ezra

@MainActor
struct SeederTests {
    private func freshDefaults() throws -> UserDefaults {
        let name = "ezra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func seedsOnceWithTheDemoContentOnTheRightLists() throws {
        let (workspace, _) = try makeWorkspace()
        let defaults = try freshDefaults()
        try Seeder.prepare(context: workspace.context, defaults: defaults)
        try Seeder.prepare(context: workspace.context, defaults: defaults)

        let all = try workspace.allToDos()
        #expect(all.count == Fixtures.todos.count)
        #expect(all.filter { !$0.isDemo }.isEmpty)
        #expect(try workspace.areas().map(\.name) == ["Family", "Work", "Health", "Home", "Money", "Side Projects"])
        #expect(try workspace.projects().count == 15)

        let party = try workspace.findToDo("Buy party decorations")
        #expect(party.project?.name == "Throw Party for Eve" && party.heading?.title == "Decorations")
        #expect(party.sortedChecklist.map(\.title) == ["Balloons", "Party hats", "Streamers"])
        #expect(party.tags == ["Errand"] && party.daysToDeadline() == 0)
        #expect(SmartList.today.contains(party))

        #expect(try workspace.tasks(in: .inbox).count == 10)
        #expect(try workspace.tasks(in: .today).filter(\.evening).count == 5)
        #expect(try workspace.tasks(in: .logbook).count == 26)
        #expect(try workspace.tasks(in: .someday).count == 13)
    }

    @Test func demoDatesMoveForwardWithTheCalendar() throws {
        let (workspace, _) = try makeWorkspace()
        let defaults = try freshDefaults()
        let seedDay = Date.now
        try Seeder.prepare(context: workspace.context, defaults: defaults, now: seedDay)
        let later = SmartList.day(3, from: seedDay).addingTimeInterval(3600)

        try Seeder.prepare(context: workspace.context, defaults: defaults, now: later)

        let party = try workspace.findToDo("Buy party decorations")
        #expect(party.startDate == SmartList.day(3, from: seedDay))
        #expect(party.daysToDeadline(now: later) == 0)
        #expect(SmartList.today.contains(party, now: later))
        // Running again on the same day moves nothing further.
        try Seeder.prepare(context: workspace.context, defaults: defaults, now: later)
        #expect(party.startDate == SmartList.day(3, from: seedDay))
    }

    @Test func resetAndRemoveLeaveTheUsersOwnItemsAlone() throws {
        let (workspace, _) = try makeWorkspace()
        let defaults = try freshDefaults()
        try workspace.addToDo(title: "Mine")
        try Seeder.prepare(context: workspace.context, defaults: defaults)
        try workspace.delete(try workspace.findToDo("Buy party decorations"))

        try Seeder.reset(context: workspace.context, defaults: defaults)
        #expect(try workspace.allToDos().count == Fixtures.todos.count + 1)

        try Seeder.removeDemo(context: workspace.context)
        #expect(try workspace.allToDos().map(\.title) == ["Mine"])
        #expect(try workspace.projects().isEmpty)
        #expect(try workspace.areas().isEmpty)
    }
}

@MainActor
struct ToDoFlowTests {
    @Test func reorderingMovesWithinTheShownRunOnly() throws {
        let (workspace, _) = try makeWorkspace()
        let titles = ["a", "b", "other", "c"]
        let todos = try titles.map { try workspace.addToDo(title: $0) }
        let shown = [todos[0], todos[1], todos[3]]

        try workspace.reorder(shown, from: IndexSet(integer: 2), to: 0)

        #expect(try workspace.allToDos().map(\.title) == ["c", "a", "other", "b"])
    }

    @Test func filingAnInboxToDoMakesItAnytimeAndDeletingItsAreaSendsItBack() throws {
        let (workspace, _) = try makeWorkspace()
        let area = try workspace.addArea(name: "Home")
        let todo = try workspace.addToDo(title: "Fix tap")
        #expect(todo.when == .inbox)

        try workspace.move(todo, to: nil, area: area)
        #expect(todo.when == .anytime && area.openToDos == [todo])

        try workspace.delete(area)
        #expect(todo.when == .inbox && todo.area == nil)
    }

    @Test func aNewToDoAppearsInTheListThatIsOpenAndAnUntitledOneIsDiscarded() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        let existing = try workspace.addToDo(title: "Existing", project: project)
        let app = AppModel()
        app.context = workspace.context

        app.destination = .project(project)
        app.newToDo()
        let fresh = try #require(app.card?.todo)
        #expect(app.card?.isNew == true && fresh.project == project && fresh.when == .anytime)
        #expect(project.openTasks == [fresh, existing]) // new to-dos go to the top
        fresh.title = "Write copy"
        app.closeCard()
        #expect(try workspace.findToDo("Write copy").project == project)

        // Closing, or opening something else, throws away a to-do that never got a title.
        app.destination = .list(.anytime)
        app.newToDo()
        #expect(app.card?.todo.when == .anytime)
        app.open(existing)
        #expect(app.card?.todo == existing)
        app.destination = .list(.someday)
        app.newToDo()
        #expect(app.card?.todo.when == .someday)
        app.closeCard()
        #expect(try workspace.allToDos().map(\.title).sorted() == ["Existing", "Write copy"])
    }

    @Test func droppingAToDoMovesItAndDroppingTheMagicPlusCreatesOneThere() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        let first = try workspace.addToDo(title: "First", schedule: .on(.now))
        let second = try workspace.addToDo(title: "Second", schedule: .on(.now))
        let loose = try workspace.addToDo(title: "Loose")
        let app = AppModel()
        app.context = workspace.context
        let friday = SmartList.day(3)

        app.drop(.todo(loose), on: .day(friday))
        #expect(loose.when == .dated && loose.startDate == friday)

        app.drop(.todo(loose), on: .project(project))
        #expect(loose.project == project)

        app.drop(.todo(loose), on: .list(.inbox))
        #expect(loose.when == .inbox && loose.project == nil)

        // Onto a bucket of today's planner, just above "First": takes the bucket, today's date and that position.
        app.drop(.todo(loose), on: .bucket(.fire, backlog: false, before: first))
        #expect(loose.bucket == .fire && SmartList.today.contains(loose))
        #expect(Planner.todos(on: .now, from: try workspace.allToDos()).map(\.title) == ["Loose", "First", "Second"])

        app.drop(.todo(second), on: .bucket(.growth, backlog: true, before: nil))
        #expect(second.bucket == .growth && second.when == .inbox)

        app.drop(.todo(first), on: .list(.logbook))
        #expect(first.isCompleted)

        app.drop(.magicPlus, on: .bucket(.growth, backlog: false, before: nil))
        let created = try #require(app.card?.todo)
        #expect(created.bucket == .growth && SmartList.today.contains(created) && app.card?.isNew == true)
    }

    @Test func aDraggedToDoTakesThePlaceOfEachRowItPassesAndLandsOnTheZoneUnderIt() throws {
        let (workspace, _) = try makeWorkspace()
        let rows = try ["a", "b", "c"].map { try workspace.addToDo(title: $0) }
        let app = AppModel()
        app.context = workspace.context
        let run = UUID()
        func layOut() throws {
            let shown = try workspace.tasks(in: .inbox)
            app.runs[run] = shown
            app.slots = [:]
            for (index, todo) in shown.enumerated() {
                app.slots[UUID()] = RowSlot(frame: CGRect(x: 0, y: index * 40, width: 300, height: 40), todo: todo, runID: run, fallback: nil)
            }
        }
        try layOut()
        app.zones[UUID()] = DropZone(frame: CGRect(x: 400, y: 0, width: 100, height: 30), target: .list(.someday))
        let origin = CGRect(x: 0, y: 80, width: 300, height: 40)

        // "c" is lifted and dragged up over "b", then over "a": each time it takes that row's place.
        app.dragChanged(.todo(rows[2]), at: CGPoint(x: 50, y: 60), from: origin)
        #expect(app.drag?.item == .todo(rows[2]) && app.drag?.grabOffset == CGSize(width: 50, height: -20))
        #expect(try workspace.tasks(in: .inbox).map(\.title) == ["a", "c", "b"])
        try layOut()
        app.dragChanged(.todo(rows[2]), at: CGPoint(x: 50, y: 10), from: origin)
        #expect(try workspace.tasks(in: .inbox).map(\.title) == ["c", "a", "b"])
        try layOut()

        // Released over its own new slot: it stays, and the drag is over.
        app.dragEnded()
        #expect(app.drag == nil)
        #expect(try workspace.tasks(in: .inbox).map(\.title) == ["c", "a", "b"])

        // Dragged out onto the Someday zone and released there.
        app.dragChanged(.todo(rows[0]), at: CGPoint(x: 450, y: 15), from: CGRect(x: 0, y: 40, width: 300, height: 40))
        #expect(app.hoverZone != nil)
        app.dragEnded()
        #expect(rows[0].when == .someday && app.hoverZone == nil)
    }

    @Test func jumpingToAToDoShowsWhereItLives() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        let inProject = try workspace.addToDo(title: "In project", project: project)
        let evening = try workspace.addToDo(title: "Tonight", schedule: .on(.now, evening: true))
        let done = try workspace.addToDo(title: "Done")
        try workspace.setCompleted(done, true)
        let app = AppModel()

        app.jump(to: inProject)
        #expect(app.destination == .project(project) && app.card?.todo == inProject)
        app.jump(to: evening)
        #expect(app.destination == .list(.today) && evening.isThisEvening)
        app.closeCard()
        app.jump(to: done)
        #expect(app.destination == .list(.logbook) && app.card == nil)
    }

    @Test func clearingTheLogbookDeletesOnlyCompletedToDos() throws {
        let (workspace, _) = try makeWorkspace()
        try workspace.addToDo(title: "Open")
        try workspace.setCompleted(try workspace.addToDo(title: "Done"), true)
        try workspace.clearLogbook()
        #expect(try workspace.allToDos().map(\.title) == ["Open"])
    }

    /// The whole window, sidebar and main area, as the app shows it: a to-do dragged out of the main area
    /// and released over a sidebar list, a project and a day changes accordingly.
    @Test func draggingFromTheMainAreaOntoTheSidebarChangesTheToDo() async throws {
        let (workspace, container) = try makeWorkspace()
        let project = try workspace.addProject(name: "Launch")
        let first = try workspace.addToDo(title: "First", schedule: .on(.now))
        let second = try workspace.addToDo(title: "Second", schedule: .on(.now))
        let app = AppModel()
        let size = CGSize(width: 1100, height: 700)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(container: container, app: app).modelContainer(container))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))

        func zone(_ matches: (DropTarget) -> Bool) throws -> CGRect {
            let frame = try #require(app.zones.values.first { matches($0.target) }?.frame)
            try #require(!frame.isNull && frame.width > 0)
            return frame
        }
        func drag(_ todo: ToDo, onto frame: CGRect) throws {
            let origin = try #require(app.slots.values.first { $0.todo == todo }?.frame)
            try #require(!origin.isNull)
            app.dragChanged(.todo(todo), at: CGPoint(x: origin.minX + 40, y: origin.midY), from: origin)
            app.dragChanged(.todo(todo), at: CGPoint(x: frame.midX, y: frame.midY), from: origin)
            #expect(app.hoverZone != nil, "nothing lit up under the pointer")
            app.dragEnded()
        }

        let someday = try zone { if case .list(.someday) = $0 { true } else { false } }
        let source = try #require(app.slots.values.first { $0.todo == first }?.frame)
        #expect(someday.maxX < source.minX, "the sidebar should lie to the left of the main area in window coordinates")
        try drag(first, onto: someday)
        #expect(first.when == .someday)

        try await Task.sleep(for: .seconds(0.6))
        try drag(second, onto: try zone { if case .project(let target) = $0 { target == project } else { false } })
        #expect(second.project == project)

        app.destination = .planner
        try await Task.sleep(for: .seconds(1.2))
        let friday = SmartList.day(2)
        try drag(second, onto: try zone { if case .day(let day) = $0 { day == friday } else { false } })
        #expect(second.when == .dated && second.startDate == friday)
    }
    @Test func filesAttachToANoteMoveWithTheFolderAndGoWhenRemoved() throws {
        let (workspace, _) = try makeWorkspace()
        let note = try workspace.addNote(title: "Trip")
        let files = FileManager.default
        let base = files.temporaryDirectory.appending(path: "ezra-test-\(UUID().uuidString)")
        let store = AttachmentStore(localFolder: base.appending(path: "local"), restoresChoice: false)
        let source = base.appending(path: "itinerary.pdf")
        try files.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048).write(to: source)

        let attachment = try store.attach(fileAt: source, to: note, in: workspace.context)
        #expect(note.sortedAttachments == [attachment] && attachment.byteCount == 2048)
        #expect(store.hasFile(for: attachment) && files.fileExists(atPath: source.path)) // the original is copied, not moved

        // Choosing a folder later takes the files gathered so far along.
        let chosen = base.appending(path: "iCloud")
        try store.use(chosen)
        #expect(store.url(for: attachment).deletingLastPathComponent().path == chosen.path)
        #expect(store.hasFile(for: attachment))

        try store.remove(attachment, in: workspace.context)
        #expect(note.sortedAttachments.isEmpty)
        #expect(try files.contentsOfDirectory(atPath: chosen.path).isEmpty)
    }
}
