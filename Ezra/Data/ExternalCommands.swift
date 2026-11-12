import Foundation
import SwiftData

/// A request from outside the app to add a to-do: a link such as
/// `ezra:///add?title=Call%20Sam&when=tomorrow%202pm&list=Launch&tags=Work,Calls`.
/// This is how Claude, other agents, scripts and Shortcuts hand Ezra a to-do without touching its database.
struct AddCommand: Equatable {
    var title: String
    var notes = ""
    /// Anything the When field understands: "today", "evening", "someday", "fri", "in 3 days", "2026-12-01", "tom 2pm".
    var when: String?
    var deadline: String?
    var tags: [String] = []
    var checklist: [String] = []
    /// "inbox", "today", "anytime", "someday", or the name of a project or area.
    var list: String?
    /// A heading inside the project named by `list`.
    var heading: String?

    init(title: String) {
        self.title = title
    }

    /// Reads `ezra:///add?…` or `ezra://add?…`. Nil for any other link.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "ezra", url.host() == "add" || url.path() == "/add",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let values = Dictionary(items.map { ($0.name.lowercased(), $0.value ?? "") }) { first, _ in first }
        func list(_ key: String, separator: Character) -> [String] {
            (values[key] ?? "").split(separator: separator).map { String($0).trimmed }.filter { !$0.isEmpty }
        }
        self.init(title: values["title"] ?? "")
        notes = values["notes"] ?? ""
        when = values["when"].nonEmpty
        deadline = values["deadline"].nonEmpty
        tags = list("tags", separator: ",")
        checklist = list("checklist-items", separator: "\n")
        self.list = values["list"].nonEmpty
        heading = values["heading"].nonEmpty
    }

    /// Creates the to-do. Throws, creating nothing, when the title is empty or a date, list or heading is not understood.
    @MainActor
    @discardableResult
    func run(in workspace: Workspace, now: Date = .now) throws -> ToDo {
        var schedule = Schedule.unscheduled
        var reminder: Date?
        if let when {
            guard let meaning = WhenPhrase.suggestions(for: when, now: now).first else { throw WorkspaceError.badDate(when) }
            schedule = meaning.date.map { .on($0, evening: meaning.evening) } ?? .someday
            reminder = meaning.reminderDate
        }
        var due: Date?
        if let deadline {
            guard let day = WhenPhrase.suggestions(for: deadline, now: now).first?.date else { throw WorkspaceError.badDate(deadline) }
            due = day
        }
        var project: Project?
        var area: Area?
        if let list {
            switch SmartList(rawValue: list.lowercased()) {
            case .inbox: break
            case .today: if when == nil { schedule = .on(now) }
            case .upcoming: if when == nil { schedule = .on(SmartList.day(1, from: now)) }
            case .anytime: if when == nil { schedule = .anytime }
            case .someday: if when == nil { schedule = .someday }
            case .logbook, nil:
                if let found = try? workspace.findProject(list) { // not a project name: try it as an area before giving up
                    project = found
                } else if let found = try workspace.areas().first(where: { $0.name.localizedCaseInsensitiveCompare(list) == .orderedSame }) {
                    area = found
                } else {
                    throw WorkspaceError.notFound(kind: "list, project or area", query: list)
                }
            }
        }
        var section: Heading?
        if let heading {
            guard let found = project?.sortedHeadings.first(where: { $0.title.localizedCaseInsensitiveCompare(heading) == .orderedSame }) else {
                throw WorkspaceError.notFound(kind: "heading", query: heading)
            }
            section = found
        }
        let todo = try workspace.addToDo(
            title: title, notes: notes, project: project, area: area, heading: section,
            schedule: schedule, deadline: due, reminderAt: reminder, tags: tags
        )
        for item in checklist {
            let entry = ChecklistItem(title: item)
            workspace.context.insert(entry)
            entry.task = todo
        }
        try workspace.context.save()
        return todo
    }
}
