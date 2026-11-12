import Foundation
import SwiftData

/// One conversation with the assistant.
@Model
final class ChatThread {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    /// The first thing the user said, shortened.
    var title: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// Kept at the top of the history.
    var pinned: Bool = false
    /// The folder it is filed in; empty for none.
    var folder: String = ""
    /// What the user told the assistant to keep to in this chat.
    var instructions: String = ""
    /// The chat's own settings, as JSON; see `params`.
    var paramsData: Data?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread) var messages: [ChatMessage]? = []

    var sortedMessages: [ChatMessage] { (messages ?? []).sorted { $0.createdAt < $1.createdAt } }

    init(title: String) {
        self.title = title
    }
}

/// One thing said in a conversation: by the user, by the assistant, or a failed turn's explanation.
@Model
final class ChatMessage {
    var uuid: UUID = UUID()
    var roleRaw: String = "user"
    var text: String = ""
    /// What the assistant changed while producing this reply.
    var changes: [String] = []
    /// The tool calls made while producing this reply, as JSON; see `steps()`.
    var stepsData: Data?
    var createdAt: Date = Date.now
    var thread: ChatThread?

    init(roleRaw: String, text: String, changes: [String] = []) {
        self.roleRaw = roleRaw
        self.text = text
        self.changes = changes
    }
}

/// A file attached to a note. The file itself lives in the attachments folder; this records which note it belongs to.
@Model
final class Attachment {
    var uuid: UUID = UUID()
    var filename: String = ""
    var byteCount: Int = 0
    var createdAt: Date = Date.now
    var note: Note?

    /// The name of its file in the attachments folder: unique, and still recognisable in Finder.
    var storedName: String { "\(uuid.uuidString)-\(filename)" }

    init(filename: String, byteCount: Int) {
        self.filename = filename
        self.byteCount = byteCount
    }
}
