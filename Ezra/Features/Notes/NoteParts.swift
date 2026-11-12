import SwiftData
import SwiftUI

/// The files on a note: click to open, right-click to reveal or remove.
struct AttachmentList: View {
    let attachments: [Attachment]
    @Environment(\.modelContext) private var context
    private let store = AttachmentStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                let isHere = store.hasFile(for: attachment)
                Button {
                    if isHere {
                        NSWorkspace.shared.open(store.url(for: attachment))
                    } else {
                        Alerts.shared.message = "“\(attachment.filename)” has not reached this Mac yet. It arrives through the attachments folder once that folder has synced."
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isHere ? "paperclip" : "icloud.and.arrow.down")
                        Text(attachment.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                            .foregroundStyle(Brand.Palette.secondary)
                    }
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(isHere ? Brand.Palette.ink : Brand.Palette.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 9)
                    .background(Brand.Palette.field.opacity(0.8), in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.hand)
                .contextMenu {
                    if isHere {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url(for: attachment)]) }
                    }
                    Button("Remove", role: .destructive) {
                        Alerts.shared.attempt("remove the attachment") { try store.remove(attachment, in: context) }
                    }
                }
            }
        }
    }
}

struct MarkdownPage: View {
    @Binding var source: String

    var body: some View {
        let blocks = NoteMarkdown.blocks(source)
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(blocks.indices, id: \.self) { index in
                    view(for: blocks[index], line: index)
                }
            }
            .font(.system(size: 14))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, line: Int) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(NoteMarkdown.inline(text))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .bold))
                .padding(.top, 8)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Brand.Palette.secondary)
                Text(NoteMarkdown.inline(text))
            }
        case .checkbox(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    source = NoteMarkdown.togglingCheckbox(atLine: line, in: source)
                } label: {
                    CheckBox(checked: done, size: 14)
                }
                .buttonStyle(.hand)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(NoteMarkdown.inline(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? Brand.Palette.secondary : Brand.Palette.ink)
            }
        case .paragraph(let text):
            Text(NoteMarkdown.inline(text))
        case .blank:
            Spacer().frame(height: 5)
        }
    }
}

/// Under a note: the notes that link to it and the to-dos that mention it, with a way to add one.
struct NoteLinksSection: View {
    let note: Note
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query private var allNotes: [Note]
    @Query(sort: \ToDo.order) private var allToDos: [ToDo]
    @State private var newTitle = ""

    var body: some View {
        // Read through the queries so the section follows edits made anywhere.
        let _ = (allNotes.count, allToDos.count)
        let workspace = Workspace(context: context)
        let found = Result { (try workspace.backlinks(to: note), try workspace.todos(linking: note)) }
        let (backlinks, todos) = (try? found.get()) ?? ([], [])
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
            if case .failure(let error) = found {
                Label("Links could not be read: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.Palette.deadline)
            }
            if !backlinks.isEmpty {
                HStack(spacing: 6) {
                    Text("Linked from").foregroundStyle(Brand.Palette.secondary)
                    ForEach(backlinks) { other in
                        Button(other.title) { app.noteToOpen = other }
                            .foregroundStyle(Brand.Palette.accent)
                            .lineLimit(1)
                    }
                }
            }
            ForEach(todos) { todo in
                HStack(spacing: 8) {
                    Button {
                        Alerts.shared.attempt("change the to-do") { try workspace.setCompleted(todo, !todo.isCompleted) }
                    } label: {
                        CheckBox(checked: todo.isCompleted)
                    }
                    Button(todo.title) { app.jump(to: todo) }
                        .strikethrough(todo.isCompleted)
                        .foregroundStyle(todo.isCompleted ? Brand.Palette.secondary : Brand.Palette.ink)
                        .help("Go to this to-do")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(Brand.Palette.secondary)
                TextField("New to-do linked to this note", text: $newTitle)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard !newTitle.trimmed.isEmpty else { return }
                        Alerts.shared.attempt("add the to-do") {
                            try workspace.addToDo(for: note, title: newTitle)
                            newTitle = ""
                        }
                    }
            }
            Text("Write [[\(note.title)]] in another note or in a to-do's notes to link it here.")
                .font(.system(size: 10.5))
                .foregroundStyle(Brand.Palette.secondary.opacity(0.8))
        }
        .font(Brand.Fonts.subtitle)
        .buttonStyle(.hand)
        .padding(.top, 10)
    }
}

/// On an open to-do: the notes its text links to, as chips that open them.
struct LinkedNoteChips: View {
    let text: String
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        let titles = NoteLinks.titles(in: text)
        if !titles.isEmpty {
            HStack(spacing: 6) {
                ForEach(titles, id: \.self) { title in
                    Button {
                        Alerts.shared.attempt("open the linked note") {
                            guard let note = try Workspace(context: context).note(titled: title) else {
                                throw WorkspaceError.notFound(kind: "note", query: title)
                            }
                            app.closeCard()
                            (app.noteToOpen, app.destination) = (note, .notes(nil))
                        }
                    } label: {
                        Label(title, systemImage: "note.text")
                            .font(Brand.Fonts.subtitle)
                            .foregroundStyle(Brand.Palette.accent)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Brand.Palette.accent.opacity(0.1), in: .capsule)
                    }
                    .buttonStyle(.hand)
                    .help("Open this note")
                }
            }
        }
    }
}
