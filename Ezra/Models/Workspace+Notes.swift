import Foundation
import SwiftData

extension Workspace {
    // MARK: Notes

    @discardableResult
    func addNote(title: String, body: String = "", project: Project? = nil) throws -> Note {
        let note = Note(title: try Self.cleaned(title, kind: "note"), body: body)
        // A new note goes to the top of the list.
        note.order = (try notes().map(\.order).min() ?? 0) - 1
        context.insert(note)
        note.project = project
        try context.save()
        return note
    }

    func append(_ text: String, to note: Note) throws {
        note.body = note.body.isEmpty ? text : note.body + "\n\n" + text
        note.updatedAt = .now
        try context.save()
    }

    func delete(_ note: Note) throws {
        context.delete(note)
        try context.save()
    }
}
