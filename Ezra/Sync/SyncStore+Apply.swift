import Foundation
import SwiftData

extension SyncStore {
    /// Applies items that arrived from other devices: creates, updates and deletes, then connects each item to the
    /// project, area, heading, event or to-do it belongs to. Items in `skipping` have unsent local edits and are left alone.
    func apply(_ items: [RemoteItem], skipping: Set<String>, reminders: ReminderScheduler?) throws {
        func index<Model: Identified>(_ type: Model.Type) throws -> [UUID: Model] {
            Dictionary(try all(type).map { ($0.uuid, $0) }) { first, _ in first }
        }
        var areas = try index(Area.self), projects = try index(Project.self), headings = try index(Heading.self)
        var events = try index(PlannerEvent.self), todos = try index(ToDo.self)
        var checklist = try index(ChecklistItem.self), notes = try index(Note.self)
        var chats = try index(ChatThread.self), messages = try index(ChatMessage.self), attachments = try index(Attachment.self)
        var links: [() -> Void] = []
        var touched: [ToDo] = []
        let decoder = JSONDecoder()

        func found<Model: Identified>(_ existing: Model?, _ id: UUID, make: () -> Model) -> Model {
            if let existing { return existing }
            let model = make()
            model.uuid = id
            context.insert(model)
            return model
        }

        for item in items where !skipping.contains(item.id) {
            guard let id = UUID(uuidString: item.id) else { continue }
            if item.deleted {
                let gone: [(any PersistentModel)?] = [
                    areas.removeValue(forKey: id), projects.removeValue(forKey: id), headings.removeValue(forKey: id),
                    events.removeValue(forKey: id), todos.removeValue(forKey: id), checklist.removeValue(forKey: id),
                    notes.removeValue(forKey: id), chats.removeValue(forKey: id), messages.removeValue(forKey: id),
                    attachments.removeValue(forKey: id),
                ]
                for case let model? in gone {
                    if let todo = model as? ToDo { reminders?.cancel(todo.uuid) }
                    context.delete(model)
                }
                continue
            }
            let data = Data(item.payload.utf8)
            do {
                switch SyncKind(rawValue: item.kind) {
                case .area:
                    let fields = try decoder.decode(AreaFields.self, from: data)
                    let area = found(areas[id], id) { Area(name: fields.name) }
                    (area.name, area.order, area.createdAt, area.isDemo) = (fields.name, fields.order, fields.createdAt, fields.isDemo)
                    areas[id] = area
                case .project:
                    let fields = try decoder.decode(ProjectFields.self, from: data)
                    let project = found(projects[id], id) { Project(name: fields.name) }
                    (project.name, project.details, project.deadline) = (fields.name, fields.details, fields.deadline)
                    (project.completedAt, project.order, project.createdAt, project.isDemo) = (fields.completedAt, fields.order, fields.createdAt, fields.isDemo)
                    (project.repeatRuleData, project.templateUUID, project.isBlueprint) = (fields.repeatRule, fields.template, fields.blueprint ?? false)
                    projects[id] = project
                    links.append { project.area = fields.area.flatMap { areas[$0] } }
                case .heading:
                    let fields = try decoder.decode(HeadingFields.self, from: data)
                    let heading = found(headings[id], id) { Heading(title: fields.title) }
                    (heading.title, heading.order, heading.createdAt) = (fields.title, fields.order, fields.createdAt)
                    headings[id] = heading
                    links.append { heading.project = fields.project.flatMap { projects[$0] } }
                case .event:
                    let fields = try decoder.decode(EventFields.self, from: data)
                    let event = found(events[id], id) { PlannerEvent(title: fields.title, start: fields.start, end: fields.end) }
                    (event.title, event.start, event.end, event.isAllDay) = (fields.title, fields.start, fields.end, fields.isAllDay)
                    (event.bucketRaw, event.noteBody, event.isDemo, event.createdAt) = (fields.bucketRaw, fields.noteBody, fields.isDemo, fields.createdAt)
                    events[id] = event
                    links.append { event.project = fields.project.flatMap { projects[$0] } }
                case .todo:
                    let fields = try decoder.decode(ToDoFields.self, from: data)
                    let todo = found(todos[id], id) { ToDo(title: fields.title) }
                    (todo.title, todo.notes, todo.whenRaw, todo.startDate, todo.evening) = (fields.title, fields.notes, fields.whenRaw, fields.startDate, fields.evening)
                    (todo.deadline, todo.reminderAt, todo.tags, todo.completedAt) = (fields.deadline, fields.reminderAt, fields.tags, fields.completedAt)
                    (todo.createdAt, todo.order, todo.isDemo, todo.bucketRaw) = (fields.createdAt, fields.order, fields.isDemo, fields.bucketRaw)
                    (todo.repeatRuleData, todo.templateUUID, todo.noteIDs) = (fields.repeatRule, fields.template, fields.noteIDs ?? [])
                    todos[id] = todo
                    touched.append(todo)
                    links.append {
                        todo.project = fields.project.flatMap { projects[$0] }
                        todo.area = fields.area.flatMap { areas[$0] }
                        todo.heading = fields.heading.flatMap { headings[$0] }
                        todo.event = fields.event.flatMap { events[$0] }
                    }
                case .checklist:
                    let fields = try decoder.decode(ChecklistFields.self, from: data)
                    let entry = found(checklist[id], id) { ChecklistItem(title: fields.title) }
                    (entry.title, entry.isDone, entry.createdAt) = (fields.title, fields.isDone, fields.createdAt)
                    checklist[id] = entry
                    links.append { entry.task = fields.task.flatMap { todos[$0] } }
                case .note:
                    let fields = try decoder.decode(NoteFields.self, from: data)
                    let note = found(notes[id], id) { Note(title: fields.title) }
                    (note.title, note.body, note.createdAt, note.updatedAt) = (fields.title, fields.body, fields.createdAt, fields.updatedAt)
                    note.order = fields.order ?? 0
                    notes[id] = note
                    links.append {
                        note.project = fields.project.flatMap { projects[$0] }
                        note.area = fields.area.flatMap { areas[$0] }
                        note.heading = fields.heading.flatMap { headings[$0] }
                    }
                case .chat:
                    let fields = try decoder.decode(ChatFields.self, from: data)
                    let thread = found(chats[id], id) { ChatThread(title: fields.title) }
                    (thread.title, thread.createdAt, thread.updatedAt) = (fields.title, fields.createdAt, fields.updatedAt)
                    thread.pinned = fields.pinned ?? false
                    (thread.folder, thread.instructions, thread.paramsData) = (fields.folder ?? "", fields.instructions ?? "", fields.params)
                    chats[id] = thread
                case .message:
                    let fields = try decoder.decode(MessageFields.self, from: data)
                    let message = found(messages[id], id) { ChatMessage(roleRaw: fields.roleRaw, text: fields.text) }
                    (message.roleRaw, message.text, message.changes, message.createdAt) = (fields.roleRaw, fields.text, fields.changes, fields.createdAt)
                    message.stepsData = fields.steps
                    messages[id] = message
                    links.append { message.thread = fields.thread.flatMap { chats[$0] } }
                case .attachment:
                    // The record only. The file itself arrives through the attachments folder.
                    let fields = try decoder.decode(AttachmentFields.self, from: data)
                    let attachment = found(attachments[id], id) { Attachment(filename: fields.filename, byteCount: fields.byteCount) }
                    (attachment.filename, attachment.byteCount, attachment.createdAt) = (fields.filename, fields.byteCount, fields.createdAt)
                    attachments[id] = attachment
                    links.append { attachment.note = fields.note.flatMap { notes[$0] } }
                case nil:
                    Log.sync.error("Skipped an item of unknown kind \(item.kind, privacy: .public)")
                }
            } catch {
                // One unreadable item must not stop every other item from syncing.
                Log.sync.error("Skipped item \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Relationships last, once everything they can point at exists.
        links.forEach { $0() }
        try context.save()
        touched.forEach { reminders?.sync($0) }
    }
}
