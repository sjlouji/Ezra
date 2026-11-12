import SwiftData
import SwiftUI

/// What is being dragged: a to-do, the Magic Plus on its way to where a new to-do should go, or a note, project or area.
enum DragItem: Equatable {
    case todo(ToDo)
    case magicPlus
    case note(Note)
    case project(Project)
    case area(Area)
    case heading(Heading)
    case checklist(ChecklistItem)
    case chat(ChatThread)

    /// Written out: two items are the same when they carry the very same stored object.
    static func == (lhs: DragItem, rhs: DragItem) -> Bool {
        switch (lhs, rhs) {
        case (.magicPlus, .magicPlus): true
        case (.todo(let a), .todo(let b)): a === b
        case (.note(let a), .note(let b)): a === b
        case (.project(let a), .project(let b)): a === b
        case (.area(let a), .area(let b)): a === b
        case (.heading(let a), .heading(let b)): a === b
        case (.checklist(let a), .checklist(let b)): a === b
        case (.chat(let a), .chat(let b)): a === b
        default: false
        }
    }
}

/// Where a drag can end.
enum DropTarget {
    case list(SmartList)
    case project(Project)
    case area(Area)
    /// A day in the planner's week strip.
    case day(Date)
    /// An hour of a day on the week grid: the to-do gets that day, and a reminder at that time.
    case hour(Date)
    /// A heading inside a project.
    case heading(Heading)
    /// Out of whatever project or area it is in.
    case detached
    /// The Notes entry in the sidebar: a note dropped here leaves its project.
    case allNotes
    /// The pinned or unpinned part of the chat history: a chat dropped here is pinned or unpinned.
    case chats(pinned: Bool)
    /// A bucket card on the planner, optionally just above one of its to-dos.
    case bucket(Bucket, backlog: Bool, before: ToDo?)
}

/// A drag in progress. Positions are in window coordinates with the origin at the top-left.
struct DragSession {
    let item: DragItem
    var location: CGPoint
    /// Where inside the dragged view the pointer took hold, so the view does not jump under it.
    let grabOffset: CGSize
    let size: CGSize
    /// The run of rows a dragged to-do was lifted from, within which it reorders live.
    var runID: UUID?
}

/// A view on screen that accepts drops.
@MainActor
struct DropZone {
    let locate: () -> CGRect?
    let target: DropTarget

    init(frame: CGRect, target: DropTarget) {
        (locate, self.target) = ({ frame }, target)
    }

    init(probe: ProbeView, target: DropTarget) {
        (locate, self.target) = ({ [weak probe] in probe?.windowFrame() }, target)
    }

    /// Where it is right now; nowhere when it is off screen.
    var frame: CGRect { locate() ?? .null }
}

/// A to-do row on screen, as a place a dragged to-do can be moved to.
@MainActor
struct RowSlot {
    let locate: () -> CGRect?
    let todo: ToDo
    let runID: UUID
    let fallback: DropTarget?

    init(frame: CGRect, todo: ToDo, runID: UUID, fallback: DropTarget?) {
        (locate, self.todo, self.runID, self.fallback) = ({ frame }, todo, runID, fallback)
    }

    init(probe: ProbeView, todo: ToDo, runID: UUID, fallback: DropTarget?) {
        (locate, self.todo, self.runID, self.fallback) = ({ [weak probe] in probe?.windowFrame() }, todo, runID, fallback)
    }

    var frame: CGRect { locate() ?? .null }
}

extension AppModel {
    /// The pointer in the same window coordinates the probes report (origin at the window's top-left).
    static func pointer() -> CGPoint? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let location = window.mouseLocationOutsideOfEventStream
        return CGPoint(x: location.x, y: window.frame.height - location.y)
    }

    /// Follows the pointer. The first call lifts the item. While a to-do is over its own run, it moves to
    /// wherever the pointer sits among the other rows, so they part to make room.
    func dragChanged(_ item: DragItem, at location: CGPoint, from origin: CGRect) {
        if drag == nil {
            closeCard()
            NSCursor.closedHand.push()
            var session = DragSession(
                item: item, location: location,
                grabOffset: CGSize(width: location.x - origin.minX, height: location.y - origin.minY), size: origin.size
            )
            if case .todo(let dragged) = item {
                let own = slots.values.filter { $0.todo == dragged }
                session.runID = (own.first { $0.frame == origin } ?? own.first)?.runID
            }
            withAnimation(Self.spring) { drag = session }
        }
        drag?.location = location

        let isOverOwnRun = reorderWithinRun(at: location) || sortAmongRows(at: location)
        let hovered = isOverOwnRun ? nil : (foreignSlot(at: location) == nil ? zone(at: location) : nil)
        if !isOverOwnRun, hovered?.key != hoverZone {
            withAnimation(.easeOut(duration: 0.12)) {
                hoverZone = hovered?.key
                dropHint = hovered.flatMap { item.hint(for: $0.value.target) }
            }
        } else if isOverOwnRun, insertion == nil, hoverZone != nil {
            withAnimation(.easeOut(duration: 0.12)) { (hoverZone, dropHint) = (nil, nil) }
        }
    }

    /// True when the pointer is over the dragged to-do's own run. Its position there is the number of other
    /// rows whose middle the pointer has passed; comparing middles keeps a row that is still sliding from swapping back.
    private func reorderWithinRun(at location: CGPoint) -> Bool {
        guard let session = drag, case .todo(let dragged) = session.item, let runID = session.runID,
              let run = runs[runID], let from = run.firstIndex(of: dragged)
        else { return false }
        let rows = slots.values.filter { $0.runID == runID }
        guard let top = rows.map(\.frame.minY).min(), let bottom = rows.map(\.frame.maxY).max(),
              let left = rows.map(\.frame.minX).min(), let right = rows.map(\.frame.maxX).max(),
              (left...right).contains(location.x), (top - 24...bottom + 24).contains(location.y)
        else { return false }
        let to = rows.count { $0.todo != dragged && $0.frame.midY < location.y }
        if to != from, let context {
            Alerts.shared.attempt("reorder") {
                try withAnimation(Self.spring) {
                    try Workspace(context: context).reorder(run, from: IndexSet(integer: from), to: to > from ? to + 1 : to)
                }
            }
        }
        return true
    }

    /// Ends the drag where the pointer is: in its own run (already in place), on a row of another run,
    /// on a drop zone, or nowhere (the item settles back).
    func dragEnded() {
        guard let session = drag else { return }
        let wasOverOwnRun = reorderWithinRun(at: session.location) || sortAmongRows(at: session.location, commit: true)
        let target = wasOverOwnRun ? nil : foreignSlot(at: session.location).map(\.fallback) ?? zone(at: session.location)?.value.target
        NSCursor.pop()
        withAnimation(Self.spring) {
            drag = nil
            hoverZone = nil
            dropHint = nil
            insertion = nil
        }
        if let target { drop(session.item, on: target) }
    }

    /// Applies a drop: a to-do is moved to the target, the Magic Plus creates a to-do there.
    func drop(_ item: DragItem, on target: DropTarget) {
        guard let context else { return Log.store.error("Drop before the store was attached") }
        switch item {
        case .magicPlus:
            create(placement(for: target))
        case .todo(let todo):
            Alerts.shared.attempt("move the to-do") {
                try withAnimation(Self.spring) { try Workspace(context: context).place(todo, at: target, plannerDay: day) }
            }
        case .note, .project, .area, .heading, .checklist, .chat:
            Alerts.shared.attempt("move it") {
                try withAnimation(Self.spring) { try Workspace(context: context).file(item, at: target) }
            }
        }
    }

    /// The row under the pointer that belongs to a run other than the one the drag started in.
    private func foreignSlot(at location: CGPoint) -> RowSlot? {
        guard case .todo = drag?.item else { return nil }
        return slots.values.first { $0.frame.contains(location) && $0.runID != drag?.runID && drag?.item != .todo($0.todo) }
    }

    /// The smallest drop zone under the pointer that takes what is being dragged (a day cell wins over the strip it sits in).
    private func zone(at location: CGPoint) -> (key: UUID, value: DropZone)? {
        zones.filter { $0.value.frame.contains(location) && drag?.item.accepts($0.value.target) == true }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }
    }

    private func placement(for target: DropTarget) -> Placement {
        switch target {
        case .list(let list): Placement(schedule: list.newToDoSchedule())
        case .project(let project): Placement(project: project)
        case .area(let area): Placement(area: area)
        case .heading(let heading): Placement(project: heading.project)
        case .detached, .allNotes, .chats: Placement()
        case .day(let day): Placement(schedule: .on(day))
        case .hour(let moment): Placement(schedule: .on(moment))
        case .bucket(let bucket, let backlog, _): Placement(schedule: backlog ? .unscheduled : .on(day), bucket: bucket)
        }
    }
}

extension Workspace {
    /// Applies a drop of `todo` on `target`.
    func place(_ todo: ToDo, at target: DropTarget, plannerDay: Date) throws {
        switch target {
        case .list(.inbox):
            (todo.project, todo.area, todo.heading) = (nil, nil, nil)
            Self.apply(.unscheduled, to: todo)
        case .list(.today): Self.apply(.on(.now), to: todo)
        case .list(.upcoming): Self.apply(.on(SmartList.day(1)), to: todo)
        case .list(.anytime): Self.apply(.anytime, to: todo)
        case .list(.someday): Self.apply(.someday, to: todo)
        case .list(.logbook): todo.completedAt = .now
        case .project(let project): try move(todo, to: project)
        case .area(let area): try move(todo, to: nil, area: area)
        case .heading(let heading):
            try move(todo, to: heading.project)
            todo.heading = heading
        case .detached:
            (todo.project, todo.area, todo.heading) = (nil, nil, nil)
        case .allNotes, .chats:
            return
        case .day(let day): Self.apply(.on(day), to: todo)
        case .hour(let moment):
            Self.apply(.on(moment), to: todo)
            todo.reminderAt = moment
        case .bucket(let bucket, let backlog, let before):
            todo.bucket = bucket
            if backlog {
                if todo.when == .dated || todo.when == .someday { Self.apply(.unscheduled, to: todo) }
            } else if !Planner.todos(on: plannerDay, from: [todo]).contains(todo) {
                Self.apply(.on(plannerDay), to: todo)
            }
            if let before, before != todo {
                // Halfway between `before` and whatever precedes it in the overall order.
                let orders = try allToDos().filter { $0 != todo }.map(\.order)
                let previous = orders.last { $0 < before.order } ?? before.order - 1
                todo.order = (previous + before.order) / 2
            }
        }
        try context.save()
        reminders?.sync(todo)
    }
}
