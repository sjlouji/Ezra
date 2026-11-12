import SwiftData
import SwiftUI

/// The lists whose rows can be put in order by dragging, other than to-dos (which have their own runs).
enum SortGroup: Hashable {
    /// The notes shown together in one place: a project's, a heading's, an area's (by that container's ID), or the Inbox's (nil).
    case notes(PersistentIdentifier?)
    /// The projects of one area in the sidebar; nil for the projects outside any area.
    case projects(Area?)
    case areas
    /// The headings of one project.
    case headings(Project)
    /// The checklist of one to-do.
    case checklist(ToDo)
}

/// A note, project or area row on screen, as a place a dragged one of the same kind can be moved to.
@MainActor
struct SortSlot {
    let locate: () -> CGRect?
    let item: DragItem
    let group: SortGroup

    init(frame: CGRect, item: DragItem, group: SortGroup) {
        (locate, self.item, self.group) = ({ frame }, item, group)
    }

    init(probe: ProbeView, item: DragItem, group: SortGroup) {
        (locate, self.item, self.group) = ({ [weak probe] in probe?.windowFrame() }, item, group)
    }

    var frame: CGRect { locate() ?? .null }
}

extension DragItem {
    /// Items reorder only among their own kind.
    var kind: Int {
        switch self {
        case .todo: 0
        case .magicPlus: 1
        case .note: 2
        case .project: 3
        case .area: 4
        case .heading: 5
        case .checklist: 6
        case .chat: 7
        }
    }

    var symbol: String {
        switch self {
        case .note: "note.text"
        case .project: "circle"
        case .area: "cube"
        case .heading: "text.justify.left"
        case .checklist: "circle.dashed"
        case .chat: "bubble.left"
        case .todo, .magicPlus: "square"
        }
    }

    /// Notes, projects and areas reorder through `SortSlot`s.
    var isSortable: Bool { kind >= 2 }

    var title: String {
        switch self {
        case .todo(let todo): todo.title
        case .magicPlus: Brand.Words.newToDo
        case .note(let note): note.title
        case .project(let project): project.name
        case .area(let area): area.name
        case .heading(let heading): heading.title
        case .checklist(let item): item.title
        case .chat(let thread): thread.title
        }
    }

    /// Whether dropping this on `target` does something. Only such targets light up.
    func accepts(_ target: DropTarget) -> Bool {
        switch (self, target) {
        case (.todo, .chats), (.magicPlus, .chats): false
        case (.chat(let thread), .chats(let pinned)): thread.pinned != pinned
        case (.todo, _), (.magicPlus, _): true
        case (.note, .project), (.note, .area), (.note, .heading), (.note, .list(.inbox)): true
        case (.project, .area): true
        default: false
        }
    }

    /// What dropping this on `target` will do, in a few words, shown on the dragged item.
    func hint(for target: DropTarget) -> String? {
        guard accepts(target) else { return nil }
        switch (self, target) {
        case (.note, .project(let project)): return "File under \(project.name)"
        case (.note, .area(let area)): return "File under \(area.name)"
        case (.note, .heading(let heading)): return "File under \(heading.title)"
        case (.note, .list): return "Move to the Inbox"
        case (.chat, .chats(let pinned)): return pinned ? "Pin" : "Unpin"
        case (.magicPlus, .list(let list)): return "New to-do in \(list.title)"
        case (.magicPlus, .project(let project)): return "New to-do in \(project.name)"
        case (.magicPlus, .area(let area)): return "New to-do in \(area.name)"
        case (_, .list(.logbook)): return "Complete"
        case (_, .list(.upcoming)): return "Schedule for tomorrow"
        case (_, .list(let list)): return "Move to \(list.title)"
        case (_, .project(let project)): return "Move to \(project.name)"
        case (_, .area(let area)): return "Move to \(area.name)"
        case (_, .heading(let heading)): return "Move under \(heading.title)"
        case (_, .day(let day)): return "Schedule for \(day.formatted(.dateTime.weekday(.wide).day()))"
        case (_, .hour(let moment)): return "\(moment.formatted(.dateTime.weekday(.abbreviated))) at \(moment.formatted(date: .omitted, time: .shortened))"
        case (_, .evening(let late)): return late ? "Move to \(Brand.Words.thisEvening)" : "Move to \(SmartList.today.title)"
        case (_, .detached): return "Take out of its project"
        default: return nil
        }
    }
}

extension AppModel {
    /// True when a dragged note, project or area is over a list of its own kind. Within its own list it is moved at once,
    /// to wherever the pointer sits among the other rows, so they part to make room. Over another list (a project over
    /// another area's projects) a line shows where it would land, and it moves only when `commit` is true, on release:
    /// moving it earlier would rebuild the row being dragged and end the drag under the user's hand.
    func sortAmongRows(at location: CGPoint, commit: Bool = false) -> Bool {
        guard let item = drag?.item, item.isSortable else { return false }
        let all = sortSlots.values.filter { $0.item.kind == item.kind }
        let own = all.first { $0.item == item }
        for group in Set(all.map(\.group)) {
            let members = all.filter { $0.group == group }
            guard let top = members.map(\.frame.minY).min(), let bottom = members.map(\.frame.maxY).max(),
                  let left = members.map(\.frame.minX).min(), let right = members.map(\.frame.maxX).max(),
                  (left...right).contains(location.x), (top - 12...bottom + 12).contains(location.y)
            else { continue }
            // Comparing middles keeps a row that is still sliding from swapping back.
            let others = members.filter { $0.item != item }.sorted { $0.frame.midY < $1.frame.midY }
            let index = others.count { $0.frame.midY < location.y }
            let isOwnList = own?.group == group
            if let own, isOwnList, others.count(where: { $0.frame.midY < own.frame.midY }) == index {
                showInsertion(nil, hint: nil)
                return true
            }
            if !isOwnList, !commit {
                let y = index < others.count ? others[index].frame.minY : (others.last?.frame.maxY ?? top)
                showInsertion(CGRect(x: left, y: y - 1, width: right - left, height: 2), hint: Self.hint(joining: group))
                return true
            }
            showInsertion(nil, hint: nil)
            guard let context else { return true }
            Alerts.shared.attempt("reorder") {
                try withAnimation(Self.spring) {
                    try Workspace(context: context).sort(
                        item, into: group, after: index > 0 ? others[index - 1].item : nil, before: index < others.count ? others[index].item : nil
                    )
                }
            }
            return true
        }
        if insertion != nil { showInsertion(nil, hint: nil) }
        return false
    }

    private func showInsertion(_ line: CGRect?, hint: String?) {
        guard insertion != line else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            insertion = line
            hoverZone = nil
            dropHint = hint
        }
    }

    private static func hint(joining group: SortGroup) -> String? {
        switch group {
        case .projects(let area?): "Move to \(area.name)"
        case .projects(nil): "Take out of its area"
        default: nil
        }
    }
}

extension Workspace {
    /// Puts a note, project or area between two others of its kind. A project also joins the area whose list it was dropped in.
    func sort(_ item: DragItem, into group: SortGroup, after: DragItem?, before: DragItem?) throws {
        // Notes made before they could be ordered all share one position; spread them out first, in the order shown.
        if case .note = item, after.map(position) == before.map(position) || after.map(position) == position(of: item) {
            for (index, note) in try notes().enumerated() { note.order = Double(index) }
        }
        let place: Double = switch (after.map(position), before.map(position)) {
        case (let above?, let below?): (above + below) / 2
        case (let above?, nil): above + 1
        case (nil, let below?): below - 1
        case (nil, nil): position(of: item)
        }
        switch (item, group) {
        case (.note(let note), .notes): note.order = place
        case (.project(let project), .projects(let area)): (project.order, project.area) = (place, area)
        case (.area(let area), .areas): area.order = place
        case (.heading(let heading), .headings): heading.order = place
        // A checklist is shown in the order its items were made, so that time is its position.
        case (.checklist(let item), .checklist): item.createdAt = Date(timeIntervalSinceReferenceDate: place)
        default: return
        }
        try context.save()
    }

    private func position(of item: DragItem) -> Double {
        switch item {
        case .note(let note): note.order
        case .project(let project): project.order
        case .area(let area): area.order
        case .heading(let heading): heading.order
        case .checklist(let item): item.createdAt.timeIntervalSinceReferenceDate
        case .todo(let todo): todo.order
        case .magicPlus, .chat: 0
        }
    }

    /// Applies a drop of a note or project on a sidebar entry.
    func file(_ item: DragItem, at target: DropTarget) throws {
        switch (item, target) {
        case (.note(let note), .project(let project)): try move(note, to: project)
        case (.note(let note), .area(let area)): try move(note, to: nil, area: area)
        case (.note(let note), .heading(let heading)): try move(note, to: heading.project, heading: heading)
        case (.note(let note), .list(.inbox)): try move(note, to: nil)
        case (.project(let project), .area(let area)):
            project.area = area
            project.order = (area.sortedProjects.filter { $0 != project }.map(\.order).max() ?? project.order) + 1
        case (.chat(let thread), .chats(let pinned)): thread.pinned = pinned
        default: return
        }
        try context.save()
    }
}

/// Makes a note, project or area row draggable: it reorders among its own kind and can be dropped on sidebar entries.
private struct SortableModifier: ViewModifier {
    let item: DragItem
    let group: SortGroup
    let enabled: Bool
    @Environment(AppModel.self) private var app
    @State private var id = UUID()
    @State private var probe: ProbeView?

    func body(content: Content) -> some View {
        // Registered on every pass, so the slot always carries what this row stands for now.
        let _ = probe.map { app.sortSlots[id] = enabled ? SortSlot(probe: $0, item: item, group: group) : nil }
        content
            .opacity(app.drag?.item == item ? 0 : 1) // the gap a dragged row leaves
            .background { Probe { probe = $0 } }
            // Ahead of the row's own click: a press that moves is a drag, one that does not is still a click.
            .highPriorityGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in
                        guard let pointer = AppModel.pointer(), let origin = probe?.windowFrame() else { return }
                        app.dragChanged(item, at: pointer, from: origin)
                    }
                    .onEnded { _ in app.dragEnded() }
            )
            .onDisappear { app.sortSlots[id] = nil }
            .help("Drag to reorder or move")
    }
}

extension View {
    /// `enabled` false keeps the row draggable onto sidebar entries but not reorderable (a filtered list has no stable order).
    func sortable(_ item: DragItem, in group: SortGroup, enabled: Bool = true) -> some View {
        modifier(SortableModifier(item: item, group: group, enabled: enabled))
    }
}
