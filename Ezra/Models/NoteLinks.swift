import Foundation
import SwiftData

/// Links written as [[Note title]] in a note or in a to-do's notes.
enum NoteLinks {
    static let scheme = "ezra-note"
    /// Made on each use: a regex value cannot be shared between threads.
    private static var pattern: Regex<(Substring, Substring)> { /\[\[([^\[\]\n]+)\]\]/ }

    /// The note titles linked from `text`, in order, each once.
    static func titles(in text: String) -> [String] {
        var seen = Set<String>()
        return text.matches(of: pattern).map { String($0.1).trimmed }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// `text` with each [[Title]] turned into a Markdown link the app opens itself.
    static func markdown(_ text: String) -> String {
        text.replacing(pattern) { match in
            let title = String(match.1).trimmed
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "[\(title)](\(scheme):\(encoded))"
        }
    }

    /// The note title a link made by `markdown` points to; nil for any other URL.
    static func title(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding
    }
}

extension Workspace {
    /// What the assistant keeps about the user between chats lives in an ordinary note, so the user can read and edit it.
    static let memoryTitle = "What \(Brand.assistant) Remembers"

    func note(titled title: String) throws -> Note? {
        try notes().first { $0.title.localizedCaseInsensitiveCompare(title.trimmed) == .orderedSame }
    }

    /// The notes whose text links to `note`.
    func backlinks(to note: Note) throws -> [Note] {
        try notes().filter { $0 != note && links($0.body, to: note) }
    }

    /// The to-dos `note` is attached to, or whose notes link to it; open ones first.
    func todos(linking note: Note) throws -> [ToDo] {
        let id = note.uuid.uuidString
        return try allToDos().filter { !$0.isTemplate && ($0.noteIDs.contains(id) || links($0.notes, to: note)) }
            .sorted { !$0.isCompleted && $1.isCompleted }
    }

    private func links(_ text: String, to note: Note) -> Bool {
        // Most text has no link at all; that is settled without the full search.
        guard text.contains("[[") else { return false }
        return NoteLinks.titles(in: text).contains { $0.localizedCaseInsensitiveCompare(note.title.trimmed) == .orderedSame }
    }

    /// A new to-do with `note` attached, filed where the note is.
    @discardableResult
    func addToDo(for note: Note, title: String) throws -> ToDo {
        let todo = try addToDo(title: title, project: note.project, area: note.area)
        todo.heading = note.heading
        try attach(note, to: todo)
        return todo
    }

    /// One thing the assistant should keep in mind in every chat.
    func remember(_ fact: String) throws {
        let line = "- " + (try Self.cleaned(fact, kind: "memory"))
        if let memory = try note(titled: Self.memoryTitle) {
            guard !memory.body.components(separatedBy: "\n").contains(line) else { return }
            memory.body = memory.body.isEmpty ? line : memory.body + "\n" + line
            memory.updatedAt = .now
            try context.save()
        } else {
            try addNote(title: Self.memoryTitle, body: line)
        }
    }

    /// What the assistant remembers, one entry per line of its note.
    func memories() throws -> [String] {
        (try note(titled: Self.memoryTitle)?.body ?? "").components(separatedBy: "\n")
            .map { $0.trimmed.hasPrefix("- ") ? String($0.trimmed.dropFirst(2)) : $0.trimmed }.filter { !$0.isEmpty }
    }
}
