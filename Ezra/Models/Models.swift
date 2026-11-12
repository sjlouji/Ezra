import Foundation
import SwiftData

// Every stored property has a default or is optional, and every relationship is
// optional with an inverse: CloudKit sync requires that shape.

/// Where a to-do sits before it is done.
enum When: String, Codable, Sendable {
    case inbox, anytime, dated, someday
}

@Model
final class Area {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    var name: String = ""
    var order: Double = 0
    var createdAt: Date = Date.now
    var isDemo: Bool = false
    @Relationship(deleteRule: .nullify, inverse: \Project.area) var projects: [Project]? = []
    @Relationship(deleteRule: .nullify, inverse: \ToDo.area) var todos: [ToDo]? = []
    @Relationship(deleteRule: .nullify, inverse: \Note.area) var notes: [Note]? = []

    var sortedProjects: [Project] { (projects ?? []).filter { !$0.isCompleted && !$0.isTemplate }.sorted { $0.order < $1.order } }
    var openToDos: [ToDo] { (todos ?? []).filter { !$0.isCompleted && $0.project == nil }.sorted { $0.order < $1.order } }

    init(name: String) {
        self.name = name
    }
}

@Model
final class Project {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    var name: String = ""
    /// The project's own notes, shown under its title.
    var details: String = ""
    var deadline: Date?
    var completedAt: Date?
    var order: Double = 0
    var createdAt: Date = Date.now
    var isDemo: Bool = false
    var repeatRuleData: Data?
    var templateUUID: UUID?
    /// A template the user saved to make new projects from. It is not work itself.
    var isBlueprint: Bool = false
    var area: Area?
    @Relationship(deleteRule: .cascade, inverse: \Heading.project) var headings: [Heading]? = []
    @Relationship(deleteRule: .cascade, inverse: \ToDo.project) var tasks: [ToDo]? = []
    @Relationship(deleteRule: .cascade, inverse: \Note.project) var notes: [Note]? = []
    @Relationship(deleteRule: .nullify, inverse: \PlannerEvent.project) var events: [PlannerEvent]? = []

    var isCompleted: Bool { completedAt != nil }
    var openTasks: [ToDo] { (tasks ?? []).filter { !$0.isCompleted }.sorted { $0.order < $1.order } }
    var completedTasks: [ToDo] {
        (tasks ?? []).filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    var sortedHeadings: [Heading] { (headings ?? []).sorted { $0.order < $1.order } }
    /// Share of its to-dos that are done, 0 when it has none.
    var progress: Double {
        let total = (tasks ?? []).count
        return total == 0 ? 0 : Double(completedTasks.count) / Double(total)
    }

    init(name: String) {
        self.name = name
    }
}

@Model
final class Heading {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    var title: String = ""
    var order: Double = 0
    var createdAt: Date = Date.now
    var project: Project?
    @Relationship(deleteRule: .nullify, inverse: \ToDo.heading) var tasks: [ToDo]? = []
    @Relationship(deleteRule: .nullify, inverse: \Note.heading) var notes: [Note]? = []

    init(title: String) {
        self.title = title
    }
}

@Model
final class ToDo {
    /// The same on every device; what sync knows the to-do by, and what names its notification.
    var uuid: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var whenRaw: String = When.inbox.rawValue
    /// Start of the day a dated to-do is planned for.
    var startDate: Date?
    /// A dated to-do kept for This Evening.
    var evening: Bool = false
    var deadline: Date?
    var reminderAt: Date?
    var tags: [String] = []
    var completedAt: Date?
    var createdAt: Date = Date.now
    /// Manual position within whichever list shows it; lower comes first.
    var order: Double = 0
    var isDemo: Bool = false
    var bucketRaw: String = Bucket.extra.rawValue
    /// Set on a repeating to-do's template: its rule, encoded. See `repeatRule`.
    var repeatRuleData: Data?
    /// Set on a copy made from a repeating template: that template's ID.
    var templateUUID: UUID?
    /// The notes attached to this to-do, by their `uuid` as text. A note can be attached to many to-dos.
    var noteIDs: [String] = []
    var project: Project?
    var area: Area?
    var heading: Heading?
    /// The event whose note page lists this to-do.
    var event: PlannerEvent?
    @Relationship(deleteRule: .cascade, inverse: \ChecklistItem.task) var checklist: [ChecklistItem]? = []

    var when: When {
        get { When(rawValue: whenRaw) ?? .inbox }
        set { whenRaw = newValue.rawValue }
    }
    var bucket: Bucket {
        get { Bucket(rawValue: bucketRaw) ?? .extra }
        set { bucketRaw = newValue.rawValue }
    }
    var isCompleted: Bool { completedAt != nil }
    var sortedChecklist: [ChecklistItem] { (checklist ?? []).sorted { $0.createdAt < $1.createdAt } }
    /// The project's name, else the area's: where the to-do lives.
    var containerName: String? { project?.name ?? area?.name }

    init(title: String) {
        self.title = title
    }
}

@Model
final class ChecklistItem {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var createdAt: Date = Date.now
    var task: ToDo?

    init(title: String) {
        self.title = title
    }
}

@Model
final class Note {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    var title: String = ""
    /// Markdown source.
    var body: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// Where it sits in the notes list; lower is higher up. Notes that share a value fall back to newest first.
    var order: Double = 0
    /// Where the note lives: a project (under one of its headings or not), else an area, else the Inbox.
    var project: Project?
    var area: Area?
    var heading: Heading?
    @Relationship(deleteRule: .cascade, inverse: \Attachment.note) var attachments: [Attachment]? = []

    var sortedAttachments: [Attachment] { (attachments ?? []).sorted { $0.createdAt < $1.createdAt } }
    /// The project's name, else the area's: where the note lives. Nil for a note in the Inbox.
    var containerName: String? { project?.name ?? area?.name }

    init(title: String, body: String = "") {
        self.title = title
        self.body = body
    }
}
