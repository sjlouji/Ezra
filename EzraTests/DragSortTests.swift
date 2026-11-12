import Foundation
import SwiftData
import Testing
@testable import Ezra

@MainActor
struct DragSortTests {
    private func row(_ index: Int, x: CGFloat = 0) -> CGRect { CGRect(x: x, y: CGFloat(index) * 40, width: 200, height: 40) }

    /// An app whose rows sit where `row(_:)` puts them, in the order given.
    private func makeApp(_ workspace: Workspace) -> AppModel {
        let app = AppModel()
        app.context = workspace.context
        return app
    }

    private func drag(_ item: DragItem, in app: AppModel, from origin: CGRect, to point: CGPoint) {
        app.dragChanged(item, at: CGPoint(x: origin.midX, y: origin.midY), from: origin)
        app.dragChanged(item, at: point, from: origin)
        app.dragEnded()
    }

    @Test func notesMadeBeforeOrderingExistedCanBeDraggedIntoOrder() throws {
        let (workspace, _) = try makeWorkspace()
        let titles = ["A", "B", "C", "D"]
        for (index, title) in titles.enumerated() {
            let note = try workspace.addNote(title: title)
            // As saved by earlier versions: no position, newest first.
            (note.order, note.updatedAt) = (0, Date(timeIntervalSinceNow: -Double(index) * 60))
        }
        try workspace.context.save()
        #expect(try workspace.notes().map(\.title) == titles)
        let app = makeApp(workspace)
        for (index, note) in try workspace.notes().enumerated() {
            app.sortSlots[UUID()] = SortSlot(frame: row(index), item: .note(note), group: .notes(nil))
        }
        let last = try workspace.notes()[3]

        // D, lifted from the bottom, dropped between A and B.
        drag(.note(last), in: app, from: row(3), to: CGPoint(x: 100, y: 45))
        #expect(try workspace.notes().map(\.title) == ["A", "D", "B", "C"])
        #expect(app.drag == nil && app.dropHint == nil)

        // A new note still arrives at the top.
        try workspace.addNote(title: "New")
        #expect(try workspace.notes().first?.title == "New")
    }

    @Test func aNoteDroppedOnAProjectIsFiledThereAndOnNotesIsTakenOut() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Trip")
        let note = try workspace.addNote(title: "Packing list")
        let todo = try workspace.addToDo(title: "Pack", project: project)
        let app = makeApp(workspace)
        app.sortSlots[UUID()] = SortSlot(frame: row(0, x: 400), item: .note(note), group: .notes(nil))
        app.zones[UUID()] = DropZone(frame: row(2), target: .project(project))
        app.zones[UUID()] = DropZone(frame: row(4), target: .allNotes)

        app.dragChanged(.note(note), at: CGPoint(x: 500, y: 20), from: row(0, x: 400))
        app.dragChanged(.note(note), at: CGPoint(x: 100, y: 100), from: row(0, x: 400))
        #expect(app.dropHint == "File under Trip" && app.hoverZone != nil)
        app.dragEnded()
        #expect(note.project == project)

        drag(.note(note), in: app, from: row(0, x: 400), to: CGPoint(x: 100, y: 180))
        #expect(note.project == nil)

        // The Notes entry takes notes only: a to-do dragged there stays where it is and nothing lights up.
        app.dragChanged(.todo(todo), at: CGPoint(x: 500, y: 300), from: row(7, x: 400))
        app.dragChanged(.todo(todo), at: CGPoint(x: 100, y: 180), from: row(7, x: 400))
        #expect(app.hoverZone == nil && app.dropHint == nil)
        app.dragChanged(.todo(todo), at: CGPoint(x: 100, y: 100), from: row(7, x: 400))
        #expect(app.dropHint == "Move to Trip")
        app.dragEnded()
        #expect(todo.project == project)
    }

    @Test func projectsReorderMoveBetweenAreasAndAreasReorder() throws {
        let (workspace, _) = try makeWorkspace()
        let (home, work) = (try workspace.addArea(name: "Home"), try workspace.addArea(name: "Work"))
        let clean = try workspace.addProject(name: "Clean", area: home)
        let paint = try workspace.addProject(name: "Paint", area: home)
        let deck = try workspace.addProject(name: "Deck", area: work)
        let empty = try workspace.addArea(name: "Someday")
        let app = makeApp(workspace)
        // The sidebar: Home, Clean, Paint, Work, Deck, Someday.
        app.sortSlots[UUID()] = SortSlot(frame: row(0), item: .area(home), group: .areas)
        app.sortSlots[UUID()] = SortSlot(frame: row(1), item: .project(clean), group: .projects(home))
        app.sortSlots[UUID()] = SortSlot(frame: row(2), item: .project(paint), group: .projects(home))
        app.sortSlots[UUID()] = SortSlot(frame: row(4), item: .area(work), group: .areas)
        app.sortSlots[UUID()] = SortSlot(frame: row(5), item: .project(deck), group: .projects(work))
        app.sortSlots[UUID()] = SortSlot(frame: row(7), item: .area(empty), group: .areas)
        app.zones[UUID()] = DropZone(frame: row(7), target: .area(empty))
        app.zones[UUID()] = DropZone(frame: row(1), target: .project(clean))

        // Within an area: Paint above Clean. A project is not dropped "into" another project.
        drag(.project(paint), in: app, from: row(2), to: CGPoint(x: 100, y: 45))
        #expect(home.sortedProjects.map(\.name) == ["Paint", "Clean"] && paint.area == home)

        // Into another area's list, below Deck. While it is held it stays in its own area (moving it would rebuild
        // the row under the pointer); a line and a label show where it will go.
        app.dragChanged(.project(clean), at: CGPoint(x: 100, y: 60), from: row(1))
        app.dragChanged(.project(clean), at: CGPoint(x: 100, y: 238), from: row(1))
        #expect(clean.area == home && app.dropHint == "Move to Work")
        #expect(app.insertion == CGRect(x: 0, y: 239, width: 200, height: 2))
        app.dragEnded()
        #expect(app.insertion == nil && app.drag == nil)
        // A second release (the safety net firing after the gesture's own) changes nothing.
        app.dragEnded()
        #expect(work.sortedProjects.map(\.name) == ["Deck", "Clean"] && home.sortedProjects.map(\.name) == ["Paint"])

        // Onto an area that has no projects yet.
        app.dragChanged(.project(deck), at: CGPoint(x: 100, y: 220), from: row(5))
        app.dragChanged(.project(deck), at: CGPoint(x: 100, y: 300), from: row(5))
        #expect(app.dropHint == "Move to Someday")
        app.dragEnded()
        #expect(deck.area == empty)

        // Areas: Work above Home.
        drag(.area(work), in: app, from: row(4), to: CGPoint(x: 100, y: -5))
        #expect(try workspace.areas().map(\.name) == ["Work", "Home", "Someday"])
    }
}

@MainActor
struct SelectionTests {
    @Test func severalToDosArePickedAndChangedTogether() throws {
        let (workspace, _) = try makeWorkspace()
        let run = try ["A", "B", "C", "D", "E"].map { try workspace.addToDo(title: $0) }
        let project = try workspace.addProject(name: "Trip")
        let app = AppModel()
        app.context = workspace.context

        app.toggleSelection(run[1])
        app.extendSelection(to: run[3], in: run)
        #expect(app.selection.map(\.title) == ["B", "C", "D"])
        app.toggleSelection(run[2])
        app.toggleSelection(run[4])
        #expect(app.selection.map(\.title) == ["B", "D", "E"] && app.isSelected(run[4]) && !app.isSelected(run[2]))

        app.applyToSelection("tag") { try $0.addTag("Travel", to: $1) }
        #expect(run.map(\.tags) == [[], ["Travel"], [], ["Travel"], ["Travel"]] && app.selection.isEmpty)

        // Moving through the Move panel takes everything picked along.
        app.toggleSelection(run[0])
        app.toggleSelection(run[1])
        app.selection.forEach { app.drop(.todo($0), on: .project(project)) }
        app.applyToSelection("schedule") { try $0.schedule($1, .someday) }
        #expect(run.prefix(2).allSatisfy { $0.project == project && $0.when == .someday } && run[2].project == nil)

        app.toggleSelection(run[3])
        app.toggleSelection(run[4])
        app.applyToSelection("complete") { try $0.setCompleted($1, true) }
        #expect(run.map(\.isCompleted) == [false, false, false, true, true])
    }

    @Test func headingsAndChecklistItemsReorderAndChatsPinByDragging() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Trip")
        let headings = try ["Before", "During", "After"].map { try workspace.addHeading(title: $0, to: project) }
        try workspace.sort(.heading(headings[2]), into: .headings(project), after: nil, before: .heading(headings[0]))
        #expect(project.sortedHeadings.map(\.title) == ["After", "Before", "During"])

        let todo = try workspace.addToDo(title: "Pack")
        try workspace.addChecklist(["Passport", "Charger", "Socks"], to: todo)
        let items = todo.sortedChecklist
        try workspace.sort(.checklist(items[0]), into: .checklist(todo), after: .checklist(items[2]), before: nil)
        try workspace.sort(.checklist(items[2]), into: .checklist(todo), after: nil, before: .checklist(items[1]))
        #expect(todo.sortedChecklist.map(\.title) == ["Socks", "Charger", "Passport"])

        let chat = ChatThread(title: "Plan")
        workspace.context.insert(chat)
        let app = AppModel()
        app.context = workspace.context
        app.zones[UUID()] = DropZone(frame: CGRect(x: 0, y: 0, width: 200, height: 20), target: .chats(pinned: true))
        app.zones[UUID()] = DropZone(frame: CGRect(x: 0, y: 100, width: 200, height: 20), target: .chats(pinned: false))
        let origin = CGRect(x: 0, y: 140, width: 200, height: 30)
        // Over "Chats" an unpinned chat has nothing to gain, so nothing lights up; over "Pinned" it does.
        app.dragChanged(.chat(chat), at: CGPoint(x: 50, y: 150), from: origin)
        app.dragChanged(.chat(chat), at: CGPoint(x: 50, y: 110), from: origin)
        #expect(app.hoverZone == nil)
        app.dragChanged(.chat(chat), at: CGPoint(x: 50, y: 10), from: origin)
        #expect(app.dropHint == "Pin")
        app.dragEnded()
        #expect(chat.pinned)
    }
}

@MainActor
struct GestureTests {
    @Test func aTwoFingerMovementIsASwipeOnlyWhenLongAndSideways() {
        #expect(Swipe.from(dx: 90, dy: 5) == .right && Swipe.from(dx: -120, dy: 30) == .left)
        #expect(Swipe.from(dx: 40, dy: 0) == nil)   // too short
        #expect(Swipe.from(dx: 90, dy: 60) == nil)  // a diagonal scroll
        #expect(Swipe.from(dx: 5, dy: 300) == nil)
    }

    @Test func swipesOnAToDoOpenWhenOrSelectItAndElsewhereGoBackAndForward() throws {
        let (workspace, _) = try makeWorkspace()
        let todo = try workspace.addToDo(title: "Pack")
        try workspace.addChecklist(["Passport", "Charger"], to: todo)
        let project = try workspace.addProject(name: "Trip")
        let app = AppModel()
        app.context = workspace.context
        let row = CGRect(x: 300, y: 100, width: 400, height: 30)
        app.slots[UUID()] = RowSlot(frame: row, todo: todo, runID: UUID(), fallback: nil)
        let onRow = CGPoint(x: 400, y: 115), elsewhere = CGPoint(x: 400, y: 500)

        app.swiped(.left, at: onRow)
        #expect(app.selection == [todo] && app.picker == nil)
        app.swiped(.left, at: onRow)
        #expect(app.selection.isEmpty)
        app.swiped(.right, at: onRow)
        #expect(app.picker?.todo == todo)
        app.closePicker()

        // A swipe on a checklist item deletes it; a swipe right there does nothing to it.
        let items = todo.sortedChecklist
        app.sortSlots[UUID()] = SortSlot(frame: CGRect(x: 300, y: 200, width: 400, height: 24), item: .checklist(items[0]), group: .checklist(todo))
        app.swiped(.left, at: CGPoint(x: 400, y: 210))
        #expect(todo.sortedChecklist.map(\.title) == ["Charger"])

        // Elsewhere: back and forward along the screens visited.
        app.destination = .project(project)
        app.destination = .list(.upcoming)
        #expect(app.canGoBack && !app.canGoForward)
        app.swiped(.right, at: elsewhere)
        #expect(app.destination == .project(project) && app.canGoForward)
        app.swiped(.right, at: elsewhere)
        #expect(app.destination == .list(.today) && !app.canGoBack)
        app.swiped(.left, at: elsewhere)
        #expect(app.destination == .project(project))
        // Going somewhere new from the middle of the trail drops what lay ahead.
        app.destination = .planner
        #expect(!app.canGoForward && app.trail == [.list(.today), .project(project), .planner])
        // The row follows the fingers part of the way.
        app.swiping = (todo, 200)
        #expect(app.swipeOffset(for: todo) == 46)
    }

    @Test func theSidebarClosesAndOpensBySwipeAndByDraggingItsEdge() {
        let saved = UserDefaults.standard.bool(forKey: AppModel.sidebarKey)
        defer { UserDefaults.standard.set(saved, forKey: AppModel.sidebarKey) }
        let app = AppModel()
        app.sidebarHidden = false
        let (onSidebar, nearEdge, onPage) = (CGPoint(x: 120, y: 300), CGPoint(x: 90, y: 300), CGPoint(x: 600, y: 300))

        // Swiping the other way over it, or anywhere on the page, leaves it alone.
        app.swiped(.right, at: onSidebar)
        app.swiped(.left, at: onPage)
        #expect(!app.sidebarHidden && app.sidebarShown == 236)
        app.swiped(.left, at: onSidebar)
        #expect(app.sidebarHidden && app.sidebarShown == 0)
        app.swiped(.right, at: onPage)
        #expect(app.sidebarHidden)
        app.swiped(.right, at: nearEdge)
        #expect(!app.sidebarHidden)

        // Dragging the edge: the sidebar follows the pointer, then settles to whichever side it is nearer.
        app.dragSidebar(to: 150)
        #expect(app.sidebarShown == 150)
        app.dragSidebar(to: -40)
        #expect(app.sidebarShown == 0)
        app.endSidebarDrag(predicted: 60)
        #expect(app.sidebarHidden && app.sidebarDrag == nil)
        app.dragSidebar(to: 90)
        app.endSidebarDrag(predicted: 200)
        #expect(!app.sidebarHidden && app.sidebarShown == 236)
        #expect(UserDefaults.standard.bool(forKey: AppModel.sidebarKey) == false)
    }
}
