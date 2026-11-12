import Foundation
import SwiftData

enum WorkspaceError: LocalizedError, Equatable {
    case emptyName(kind: String)
    case notFound(kind: String, query: String)
    case ambiguous(kind: String, query: String, matches: [String])
    case badDate(String)

    var errorDescription: String? {
        switch self {
        case .emptyName(let kind):
            "A \(kind) needs a name."
        case .notFound(let kind, let query):
            "No \(kind) matches \"\(query)\"."
        case .ambiguous(let kind, let query, let matches):
            "More than one \(kind) matches \"\(query)\": \(matches.joined(separator: "; ")). Use the full name."
        case .badDate(let text):
            "\"\(text)\" is not a date in the form yyyy-MM-dd (or yyyy-MM-dd HH:mm for a reminder)."
        }
    }
}

/// Every change to the user's data goes through here, from the views and from the assistant alike.
@MainActor
struct Workspace {
    let context: ModelContext
    let reminders: ReminderScheduler?

    init(context: ModelContext, reminders: ReminderScheduler? = .shared) {
        self.context = context
        self.reminders = reminders
    }

    // MARK: Reading

    func allToDos() throws -> [ToDo] {
        try context.fetch(FetchDescriptor<ToDo>(sortBy: [SortDescriptor(\.order)]))
    }

    /// Open to-dos, or the to-dos of one smart list.
    func tasks(in list: SmartList? = nil, now: Date = .now) throws -> [ToDo] {
        let all = try allToDos()
        guard let list else { return all.filter { !$0.isCompleted && !$0.isTemplate && $0.project?.isTemplate != true } }
        return all.filter { list.contains($0, now: now) }
    }

    func projects() throws -> [Project] {
        try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.order)]))
    }

    func areas() throws -> [Area] {
        try context.fetch(FetchDescriptor<Area>(sortBy: [SortDescriptor(\.order)]))
    }

    func notes() throws -> [Note] {
        try context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.order), SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    func todo(withID id: UUID) throws -> ToDo? {
        try context.fetch(FetchDescriptor<ToDo>(predicate: #Predicate { $0.uuid == id })).first
    }

    func findToDo(_ query: String) throws -> ToDo {
        try Self.uniqueMatch(in: tasks(), kind: "open task", query: query, name: \.title)
    }

    func findProject(_ query: String) throws -> Project {
        try Self.uniqueMatch(in: projects(), kind: "project", query: query, name: \.name)
    }

    func findNote(_ query: String) throws -> Note {
        try Self.uniqueMatch(in: notes(), kind: "note", query: query, name: \.title)
    }

    // MARK: To-dos

    @discardableResult
    func addToDo(
        title: String,
        notes: String = "",
        project: Project? = nil,
        area: Area? = nil,
        heading: Heading? = nil,
        schedule: Schedule = .unscheduled,
        deadline: Date? = nil,
        reminderAt: Date? = nil,
        tags: [String] = []
    ) throws -> ToDo {
        let todo = ToDo(title: try Self.cleaned(title, kind: "task"))
        todo.notes = notes
        todo.deadline = deadline
        todo.reminderAt = reminderAt
        todo.tags = tags
        try insert(todo, project: project, area: area, heading: heading, schedule: schedule)
        return todo
    }

    /// Stores a new to-do at the end of everything, or at the very top. A blank title is allowed: the user is about to type it.
    func insert(
        _ todo: ToDo, project: Project?, area: Area?, heading: Heading? = nil, schedule: Schedule, atTop: Bool = false
    ) throws {
        // Only the first or the last to-do is needed for this, not all of them.
        var edge = FetchDescriptor<ToDo>(sortBy: [SortDescriptor(\.order, order: atTop ? .forward : .reverse)])
        edge.fetchLimit = 1
        let end = try context.fetch(edge).first?.order ?? 0
        todo.order = atTop ? end - 1 : end + 1
        context.insert(todo)
        todo.project = project
        todo.area = project == nil ? area : nil
        todo.heading = heading
        Self.apply(schedule, to: todo)
        try context.save()
        reminders?.sync(todo)
    }

    func setCompleted(_ todo: ToDo, _ completed: Bool) throws {
        todo.completedAt = completed ? .now : nil
        try context.save()
        reminders?.sync(todo)
        // Completing a copy of an "after completion" repeat is what schedules the next one.
        if completed, todo.templateUUID != nil { try generateRepeats() }
    }

    func schedule(_ todo: ToDo, _ schedule: Schedule) throws {
        Self.apply(schedule, to: todo)
        try context.save()
    }

    func setDeadline(_ todo: ToDo, _ date: Date?) throws {
        todo.deadline = date.map(Calendar.current.startOfDay(for:))
        try context.save()
    }

    func setReminder(_ todo: ToDo, at date: Date?) throws {
        todo.reminderAt = date
        try context.save()
        reminders?.sync(todo)
    }

    /// Files a to-do under a project or an area. One that was waiting in the Inbox becomes Anytime.
    func move(_ todo: ToDo, to project: Project?, area: Area? = nil) throws {
        todo.project = project
        todo.area = project == nil ? area : nil
        todo.heading = nil
        if todo.when == .inbox, project != nil || area != nil { todo.when = .anytime }
        try context.save()
    }

    /// Applies a drag within one shown run of to-dos, reusing that run's own positions.
    func reorder(_ shown: [ToDo], from source: IndexSet, to destination: Int) throws {
        var moved = shown
        moved.move(fromOffsets: source, toOffset: destination)
        for (todo, order) in zip(moved, shown.map(\.order).sorted()) {
            todo.order = order
        }
        try context.save()
    }

    func delete(_ todo: ToDo) throws {
        reminders?.cancel(todo.uuid)
        context.delete(todo)
        try context.save()
    }

    /// Permanently removes every completed to-do.
    func clearLogbook() throws {
        try context.fetch(FetchDescriptor<ToDo>(predicate: #Predicate { $0.completedAt != nil })).forEach(context.delete)
        try context.save()
    }

    /// Every tag in use, alphabetically.
    func allTags() throws -> [String] {
        Set(try allToDos().flatMap(\.tags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Projects and areas

    @discardableResult
    func addProject(name: String, area: Area? = nil) throws -> Project {
        let project = Project(name: try Self.cleaned(name, kind: "project"))
        project.order = (try projects().map(\.order).max() ?? 0) + 1
        context.insert(project)
        project.area = area
        try context.save()
        return project
    }

    /// Completing a project completes its open to-dos; reopening leaves them as they are.
    func setCompleted(_ project: Project, _ completed: Bool) throws {
        project.completedAt = completed ? .now : nil
        if completed {
            for todo in project.openTasks {
                todo.completedAt = .now
                reminders?.sync(todo)
            }
        }
        try context.save()
        if completed, project.templateUUID != nil { try generateRepeats() }
    }

    func delete(_ project: Project) throws {
        for todo in project.tasks ?? [] {
            reminders?.cancel(todo.uuid)
        }
        context.delete(project)
        try context.save()
    }

    @discardableResult
    func addArea(name: String) throws -> Area {
        let area = Area(name: try Self.cleaned(name, kind: "area"))
        area.order = (try areas().map(\.order).max() ?? 0) + 1
        context.insert(area)
        try context.save()
        return area
    }

    /// The area with this name, created when there is none.
    func area(named name: String) throws -> Area {
        let wanted = try Self.cleaned(name, kind: "area")
        if let existing = try areas().first(where: { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }) {
            return existing
        }
        return try addArea(name: wanted)
    }

    /// Removes the area; its projects and to-dos stay, without an area.
    func delete(_ area: Area) throws {
        for todo in area.todos ?? [] where todo.when == .anytime && todo.project == nil {
            todo.when = .inbox
        }
        context.delete(area)
        try context.save()
    }

    @discardableResult
    func addHeading(title: String, to project: Project) throws -> Heading {
        let heading = Heading(title: try Self.cleaned(title, kind: "heading"))
        heading.order = (project.sortedHeadings.last?.order ?? 0) + 1
        context.insert(heading)
        heading.project = project
        try context.save()
        return heading
    }

    // MARK: Helpers

    static func apply(_ schedule: Schedule, to todo: ToDo) {
        switch schedule {
        case .unscheduled:
            todo.when = todo.project != nil || todo.area != nil ? .anytime : .inbox
            todo.startDate = nil
            todo.evening = false
        case .anytime:
            todo.when = .anytime
            todo.startDate = nil
            todo.evening = false
        case .someday:
            todo.when = .someday
            todo.startDate = nil
            todo.evening = false
        case .on(let date, let evening):
            todo.when = .dated
            todo.startDate = Calendar.current.startOfDay(for: date)
            todo.evening = evening
        }
    }

    static func cleaned(_ name: String, kind: String) throws -> String {
        let cleaned = name.trimmed
        guard !cleaned.isEmpty else { throw WorkspaceError.emptyName(kind: kind) }
        return cleaned
    }

    /// The one item whose name equals `query`, else the one whose name contains it; case-insensitive.
    static func uniqueMatch<Item>(in items: [Item], kind: String, query: String, name: (Item) -> String) throws -> Item {
        let wanted = query.trimmed
        let exact = items.filter { name($0).localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        let candidates = exact.isEmpty ? items.filter { name($0).localizedCaseInsensitiveContains(wanted) } : exact
        switch candidates.count {
        case 0: throw WorkspaceError.notFound(kind: kind, query: wanted)
        case 1: return candidates[0]
        default: throw WorkspaceError.ambiguous(kind: kind, query: wanted, matches: candidates.prefix(5).map(name))
        }
    }
}
