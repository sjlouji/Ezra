import Foundation
import SwiftData

/// Edits to an existing to-do or project that the assistant makes in one call.
extension Workspace {
    /// Changes only what is given.
    func edit(_ todo: ToDo, title: String? = nil, notes: String? = nil, tags: [String]? = nil) throws {
        if let title { todo.title = try Self.cleaned(title, kind: "task") }
        if let notes { todo.notes = notes }
        if let tags { todo.tags = Self.tidied(tags) }
        try context.save()
    }

    /// Adds checklist items to a to-do, in the order given.
    func addChecklist(_ titles: [String], to todo: ToDo) throws {
        let start = Date.now
        for (offset, title) in titles.enumerated() where !title.trimmed.isEmpty {
            let item = ChecklistItem(title: title.trimmed)
            // The checklist is shown by creation time; a millisecond apart keeps the given order.
            item.createdAt = start.addingTimeInterval(Double(offset) / 1000)
            context.insert(item)
            item.task = todo
        }
        try context.save()
    }

    func setDetails(_ project: Project, _ text: String) throws {
        project.details = text
        try context.save()
    }

    /// Tags without blanks or repeats, keeping the first spelling of each.
    static func tidied(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(\.trimmed).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
