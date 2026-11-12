import Foundation

/// Tools for notes as part of the lists: finding them and attaching them to to-dos.
extension AgentTools {
    static let listNotes = AgentTool(
        name: "listNotes", label: "Read notes",
        about: "Lists the notes by title, with the project or area each is in. Use readNote for a note's text.",
        parameters: [Parameter(name: "project", about: "Only the notes of this project; omit for all notes")],
        onDevice: false
    ) { workspace, input in
        let project = try input.string("project").map(workspace.findProject)
        let notes = try workspace.notes().filter { $0.title != Workspace.memoryTitle && (project == nil || $0.project == project) }
        guard !notes.isEmpty else { return ToolOutcome(text: "There are no notes\(project.map { " in \($0.name)" } ?? "").") }
        return ToolOutcome(text: notes.map { "- \($0.title) [\($0.containerName ?? SmartList.inbox.title)]" }.joined(separator: "\n"))
    }

    static let attachNote = AgentTool(
        name: "attachNote", label: "Attach note",
        about: "Attaches an existing note to an open task, so the task shows it. A note can be attached to several tasks.",
        parameters: [
            Parameter(name: "task", about: "The task's title, as listed", required: true),
            Parameter(name: "note", about: "The note's title, as listed", required: true),
        ],
        changesData: true, onDevice: false
    ) { workspace, input in
        let task = try workspace.findToDo(try input.required("task"))
        let note = try workspace.findNote(try input.required("note"))
        try workspace.attach(note, to: task)
        return ToolOutcome(text: "Attached the note \(note.title) to the task \(task.title)", todos: [task.uuid])
    }
}
