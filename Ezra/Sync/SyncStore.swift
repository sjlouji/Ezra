import CryptoKit
import Foundation
import SwiftData

/// Something sync can find again by its permanent ID.
protocol Identified: PersistentModel {
    var uuid: UUID { get set }
}

extension Area: Identified {}
extension Project: Identified {}
extension Heading: Identified {}
extension ToDo: Identified {}
extension ChecklistItem: Identified {}
extension Note: Identified {}
extension PlannerEvent: Identified {}
extension ChatThread: Identified {}
extension ChatMessage: Identified {}
extension Attachment: Identified {}

enum SyncKind: String {
    case area, project, heading, event, todo, checklist, note, chat, message, attachment
}

/// One local item in the form it is sent: its kind, its permanent ID, and its fields as JSON.
struct LocalRecord: Equatable {
    let kind: SyncKind
    let id: String
    let payload: String

    /// Changes whenever any field does; how sync tells an edited item from an unchanged one.
    var fingerprint: String {
        SHA256.hash(data: Data("\(kind.rawValue)|\(payload)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AreaFields: Codable { var name: String; var order: Double; var createdAt: Date; var isDemo: Bool }
struct ProjectFields: Codable {
    var name: String; var details: String; var deadline: Date?; var completedAt: Date?
    var order: Double; var createdAt: Date; var isDemo: Bool; var area: UUID?
    var repeatRule: Data?; var template: UUID?; var blueprint: Bool?
}
struct HeadingFields: Codable { var title: String; var order: Double; var createdAt: Date; var project: UUID? }
struct EventFields: Codable {
    var title: String; var start: Date; var end: Date; var isAllDay: Bool; var bucketRaw: String
    var noteBody: String; var isDemo: Bool; var createdAt: Date; var project: UUID?
}
struct ToDoFields: Codable {
    var title: String; var notes: String; var whenRaw: String; var startDate: Date?; var evening: Bool
    var deadline: Date?; var reminderAt: Date?; var tags: [String]; var completedAt: Date?; var createdAt: Date
    var order: Double; var isDemo: Bool; var bucketRaw: String
    var project: UUID?; var area: UUID?; var heading: UUID?; var event: UUID?
    var repeatRule: Data?; var template: UUID?
    /// Left out when the to-do has no notes attached, so such to-dos read the same as before notes could be attached.
    var noteIDs: [String]?
}
struct ChecklistFields: Codable { var title: String; var isDone: Bool; var createdAt: Date; var task: UUID? }
struct ChatFields: Codable {
    var title: String; var createdAt: Date; var updatedAt: Date; var pinned: Bool?
    var folder: String?; var instructions: String?; var params: Data?
}
struct MessageFields: Codable { var roleRaw: String; var text: String; var changes: [String]; var createdAt: Date; var thread: UUID?; var steps: Data? }
struct AttachmentFields: Codable { var filename: String; var byteCount: Int; var createdAt: Date; var note: UUID? }
struct NoteFields: Codable { var title: String; var body: String; var createdAt: Date; var updatedAt: Date; var project: UUID?; var order: Double?; var area: UUID?; var heading: UUID? }

/// Turns the local database into records to send, and applies records that arrive.
@MainActor
struct SyncStore {
    let context: ModelContext

    func all<Model: PersistentModel>(_ type: Model.Type) throws -> [Model] {
        try context.fetch(FetchDescriptor<Model>())
    }

    /// Items created before IDs existed were all given the same one; each but the first gets its own.
    func repairIdentifiers() throws {
        func repair<Model: Identified>(_ type: Model.Type) throws {
            for group in Dictionary(grouping: try all(type), by: \.uuid).values where group.count > 1 {
                group.dropFirst().forEach { $0.uuid = UUID() }
            }
        }
        try repair(Area.self); try repair(Project.self); try repair(Heading.self); try repair(ToDo.self)
        try repair(ChecklistItem.self); try repair(Note.self); try repair(PlannerEvent.self)
        try repair(ChatThread.self); try repair(ChatMessage.self); try repair(Attachment.self)
        try context.save()
    }

    func snapshot() throws -> [LocalRecord] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func record(_ kind: SyncKind, _ id: UUID, _ fields: some Encodable) throws -> LocalRecord {
            LocalRecord(kind: kind, id: id.uuidString, payload: String(decoding: try encoder.encode(fields), as: UTF8.self))
        }
        var records: [LocalRecord] = []
        for area in try all(Area.self) {
            records.append(try record(.area, area.uuid, AreaFields(name: area.name, order: area.order, createdAt: area.createdAt, isDemo: area.isDemo)))
        }
        for project in try all(Project.self) {
            records.append(try record(.project, project.uuid, ProjectFields(
                name: project.name, details: project.details, deadline: project.deadline, completedAt: project.completedAt,
                order: project.order, createdAt: project.createdAt, isDemo: project.isDemo, area: project.area?.uuid,
                repeatRule: project.repeatRuleData, template: project.templateUUID, blueprint: project.isBlueprint
            )))
        }
        for heading in try all(Heading.self) {
            records.append(try record(.heading, heading.uuid, HeadingFields(
                title: heading.title, order: heading.order, createdAt: heading.createdAt, project: heading.project?.uuid
            )))
        }
        for event in try all(PlannerEvent.self) {
            records.append(try record(.event, event.uuid, EventFields(
                title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay, bucketRaw: event.bucketRaw,
                noteBody: event.noteBody, isDemo: event.isDemo, createdAt: event.createdAt, project: event.project?.uuid
            )))
        }
        for todo in try all(ToDo.self) {
            records.append(try record(.todo, todo.uuid, ToDoFields(
                title: todo.title, notes: todo.notes, whenRaw: todo.whenRaw, startDate: todo.startDate, evening: todo.evening,
                deadline: todo.deadline, reminderAt: todo.reminderAt, tags: todo.tags, completedAt: todo.completedAt,
                createdAt: todo.createdAt, order: todo.order, isDemo: todo.isDemo, bucketRaw: todo.bucketRaw,
                project: todo.project?.uuid, area: todo.area?.uuid, heading: todo.heading?.uuid, event: todo.event?.uuid,
                repeatRule: todo.repeatRuleData, template: todo.templateUUID, noteIDs: todo.noteIDs.isEmpty ? nil : todo.noteIDs
            )))
        }
        for item in try all(ChecklistItem.self) {
            records.append(try record(.checklist, item.uuid, ChecklistFields(
                title: item.title, isDone: item.isDone, createdAt: item.createdAt, task: item.task?.uuid
            )))
        }
        for note in try all(Note.self) {
            records.append(try record(.note, note.uuid, NoteFields(
                title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt, project: note.project?.uuid, order: note.order,
                area: note.area?.uuid, heading: note.heading?.uuid
            )))
        }
        for thread in try all(ChatThread.self) {
            records.append(try record(.chat, thread.uuid, ChatFields(
                title: thread.title, createdAt: thread.createdAt, updatedAt: thread.updatedAt, pinned: thread.pinned,
                folder: thread.folder, instructions: thread.instructions, params: thread.paramsData
            )))
        }
        for message in try all(ChatMessage.self) {
            records.append(try record(.message, message.uuid, MessageFields(
                roleRaw: message.roleRaw, text: message.text, changes: message.changes, createdAt: message.createdAt, thread: message.thread?.uuid, steps: message.stepsData
            )))
        }
        for attachment in try all(Attachment.self) {
            records.append(try record(.attachment, attachment.uuid, AttachmentFields(
                filename: attachment.filename, byteCount: attachment.byteCount, createdAt: attachment.createdAt, note: attachment.note?.uuid
            )))
        }
        return records
    }
}
