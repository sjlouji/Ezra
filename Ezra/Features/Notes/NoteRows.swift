import SwiftData
import SwiftUI

extension Note {
    /// Filed nowhere, so the Inbox shows it. What the assistant remembers is kept out: it is not waiting to be filed.
    @MainActor var isInInbox: Bool { project == nil && area == nil && title != Workspace.memoryTitle }
}

extension [Note] {
    /// In the user's order; notes that share a position fall back to the most recently edited first.
    var inOrder: [Note] { sorted { ($0.order, $1.updatedAt) < ($1.order, $0.updatedAt) } }
}

/// Notes as rows in a list, beside the to-dos of the same project, heading, area or Inbox. Clicking one opens its page.
struct NoteRows: View {
    let notes: [Note]
    /// The project, heading or area these notes share (nil for the Inbox): dragging reorders them within it.
    var group: PersistentIdentifier?
    /// Names each note's project or area, and turns reordering off: for a list that mixes notes from everywhere.
    var showsContainer = false
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        ForEach(notes) { note in
            Button {
                app.destination = .note(note)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.Palette.accent)
                        .frame(width: 16)
                    Text(note.title.isEmpty ? "Untitled" : note.title).font(Brand.Fonts.row).lineLimit(1)
                    Text(note.snippet).font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if showsContainer {
                        Text(note.containerName ?? SmartList.inbox.title).font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary)
                    }
                }
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.hand)
            .foregroundStyle(Brand.Palette.ink)
            .accessibilityLabel("Note: \(note.title)")
            .contextMenu { menu(for: note) }
            .sortable(.note(note), in: .notes(group), enabled: !showsContainer)
            .plainRow()
        }
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        let workspace = Workspace(context: context)
        if let project = note.project, !project.sortedHeadings.isEmpty {
            Menu("Move to Heading") {
                Button("No Heading") { Alerts.shared.attempt("move the note") { try workspace.move(note, to: project) } }
                ForEach(project.sortedHeadings) { heading in
                    Button(heading.title) { Alerts.shared.attempt("move the note") { try workspace.move(note, to: project, heading: heading) } }
                }
            }
        }
        if !note.isInInbox {
            Button("Move to Inbox") { Alerts.shared.attempt("move the note") { try workspace.move(note, to: nil) } }
        }
        Divider()
        Button("Delete Note", role: .destructive) { Alerts.shared.attempt("delete the note") { try workspace.delete(note) } }
    }
}

/// On an open to-do: its notes as chips that open them, and a menu to attach another or start a new one.
struct AttachedNotes: View {
    let todo: ToDo
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.order) private var allNotes: [Note]
    @State private var isPicking = false

    var body: some View {
        let workspace = Workspace(context: context)
        let found = Result { try workspace.attachedNotes(of: todo) }
        let attached = (try? found.get()) ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if case .failure(let error) = found {
                    Label("Notes could not be read: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Brand.Palette.deadline)
                }
                ForEach(attached) { note in
                    Button {
                        app.closeCard()
                        app.destination = .note(note)
                    } label: {
                        Label(note.title, systemImage: "doc.text")
                            .lineLimit(1)
                            .foregroundStyle(Brand.Palette.accent)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Brand.Palette.accent.opacity(0.1), in: .capsule)
                    }
                    .help("Open this note")
                    .contextMenu {
                        // A note the text links to as [[Title]] stays until that text is removed.
                        if todo.noteIDs.contains(note.uuid.uuidString) {
                            Button("Detach from This To-Do") { Alerts.shared.attempt("detach the note") { try workspace.detach(note, from: todo) } }
                        } else {
                            Text("Linked in the to-do's notes")
                        }
                    }
                }
                Button {
                    isPicking = true
                } label: {
                    Label("Attach note", systemImage: "paperclip").foregroundStyle(Brand.Palette.accent)
                }
                .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                    NotePicker(notes: choices(besides: attached)) { picked in
                        isPicking = false
                        Alerts.shared.attempt("attach the note") { try workspace.attach(picked, to: todo) }
                    } makeNew: { title in
                        isPicking = false
                        Alerts.shared.attempt("create the note") {
                            let fallback = todo.title.isEmpty ? "Untitled" : todo.title
                            let note = try workspace.addNote(title: title.trimmed.isEmpty ? fallback : title, project: todo.project, area: todo.area)
                            try workspace.attach(note, to: todo)
                            app.closeCard()
                            app.destination = .note(note)
                        }
                    }
                }
            }
            .font(Brand.Fonts.subtitle)
            .buttonStyle(.hand)
        }
    }

    /// Notes that can still be attached: those of the to-do's own project or area first, then the rest, most recently edited first.
    private func choices(besides attached: [Note]) -> [Note] {
        let free = allNotes.filter { !attached.contains($0) && $0.title != Workspace.memoryTitle }.sorted { $0.updatedAt > $1.updatedAt }
        let near = free.filter { ($0.project != nil && $0.project == todo.project) || ($0.area != nil && $0.area == todo.area) }
        return near + free.filter { !near.contains($0) }
    }
}

/// Picks a note to attach, however many there are: type to narrow the list, which scrolls; or start a new note with what was typed.
struct NotePicker: View {
    let notes: [Note]
    let pick: (Note) -> Void
    let makeNew: (String) -> Void
    @State private var search = ""
    @FocusState private var searching: Bool

    /// The notes whose title, or whose project or area, contains what was typed.
    static func matches(_ notes: [Note], _ search: String) -> [Note] {
        let text = search.trimmed
        guard !text.isEmpty else { return notes }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(text) || ($0.containerName ?? "").localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let found = Self.matches(notes, search)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.Palette.secondary)
                TextField("Find a note", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    // Return takes the first match, or starts a note with that name when nothing matches.
                    .onSubmit { if let first = found.first { pick(first) } else { makeNew(search) } }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Brand.Palette.field, in: .rect(cornerRadius: 7))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(found) { note in
                        Button { pick(note) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(Brand.Palette.accent)
                                Text(note.title.isEmpty ? "Untitled" : note.title).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(note.containerName ?? SmartList.inbox.title).foregroundStyle(Brand.Palette.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 6)
                            .contentShape(.rect)
                        }
                    }
                    if found.isEmpty {
                        Text(notes.isEmpty ? "No other notes yet" : "No note matches").foregroundStyle(Brand.Palette.secondary).padding(6)
                    }
                }
            }
            .frame(maxHeight: 260)
            Divider()
            Button { makeNew(search) } label: {
                Label(search.trimmed.isEmpty ? "New Note" : "New Note “\(search.trimmed)”", systemImage: "plus")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(.rect)
            }
            .foregroundStyle(Brand.Palette.accent)
        }
        .font(Brand.Fonts.subtitle)
        .foregroundStyle(Brand.Palette.ink)
        .buttonStyle(.hand)
        .padding(10)
        .frame(width: 340)
        .onAppear { searching = true }
    }
}
