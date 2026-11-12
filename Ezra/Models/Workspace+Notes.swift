import Foundation
import SwiftData

extension Note {
    /// The first line of the note that says something, without its Markdown marker.
    var snippet: String {
        // Only the opening of the note is looked at; a long note is not parsed whole for one line.
        for block in NoteMarkdown.blocks(String(body.prefix(400))) {
            switch block {
            case .heading(_, let text), .bullet(let text), .checkbox(_, let text), .paragraph(let text): return text
            case .blank: continue
            }
        }
        return ""
    }
}

extension Workspace {
    // MARK: Notes

    /// A new note in a project (under `heading`, when given), else in an area, else in the Inbox.
    @discardableResult
    func addNote(title: String, body: String = "", project: Project? = nil, area: Area? = nil, heading: Heading? = nil) throws -> Note {
        let note = Note(title: try Self.cleaned(title, kind: "note"), body: body)
        // A new note goes to the top of its list.
        note.order = (try notes().map(\.order).min() ?? 0) - 1
        context.insert(note)
        place(note, project: project, area: area, heading: heading)
        try context.save()
        return note
    }

    /// Moves a note to a project (under `heading`, when given), to an area, or with neither to the Inbox.
    func move(_ note: Note, to project: Project?, area: Area? = nil, heading: Heading? = nil) throws {
        place(note, project: project, area: area, heading: heading)
        try context.save()
    }

    /// A note lives in exactly one place: a heading implies its project, and a project rules out an area.
    private func place(_ note: Note, project: Project?, area: Area?, heading: Heading?) {
        let home = heading?.project ?? project
        (note.project, note.heading, note.area) = (home, heading, home == nil ? area : nil)
    }

    func append(_ text: String, to note: Note) throws {
        note.body = note.body.isEmpty ? text : note.body + "\n\n" + text
        note.updatedAt = .now
        try context.save()
    }

    /// Deletes a note and takes it off every to-do it was attached to.
    func delete(_ note: Note) throws {
        let id = note.uuid.uuidString
        for todo in try allToDos() where todo.noteIDs.contains(id) { todo.noteIDs.removeAll { $0 == id } }
        context.delete(note)
        try context.save()
    }

    // MARK: Notes on to-dos

    func attach(_ note: Note, to todo: ToDo) throws {
        let id = note.uuid.uuidString
        guard !todo.noteIDs.contains(id) else { return }
        todo.noteIDs.append(id)
        try context.save()
    }

    func detach(_ note: Note, from todo: ToDo) throws {
        todo.noteIDs.removeAll { $0 == note.uuid.uuidString }
        try context.save()
    }

    /// The notes on a to-do: those attached to it, then those its text links to as [[Title]]; each once.
    func attachedNotes(of todo: ToDo) throws -> [Note] {
        let titles = todo.notes.contains("[[") ? NoteLinks.titles(in: todo.notes).map { $0.lowercased() } : []
        guard !todo.noteIDs.isEmpty || !titles.isEmpty else { return [] }
        let all = try notes()
        let attached = todo.noteIDs.compactMap { id in all.first { $0.uuid.uuidString == id } }
        let linked = titles.compactMap { title in all.first { $0.title.trimmed.lowercased() == title } }
        return (attached + linked).reduce(into: [Note]()) { found, note in if !found.contains(note) { found.append(note) } }
    }
}
