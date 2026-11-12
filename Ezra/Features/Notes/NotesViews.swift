import SwiftData
import SwiftUI

/// The notes of one project, or every note when `project` is nil: a searchable list beside the open page.
struct NotesBrowser: View {
    let project: Project?
    @Query(sort: [SortDescriptor(\Note.order), SortDescriptor(\Note.updatedAt, order: .reverse)]) private var allNotes: [Note]
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @State private var selected: Note?
    @State private var search = ""

    private var notes: [Note] {
        let text = search.trimmed
        return allNotes.filter { note in
            (project == nil || note.project == project)
                && (text.isEmpty || note.title.localizedCaseInsensitiveContains(text) || note.body.localizedCaseInsensitiveContains(text))
        }
    }

    var body: some View {
        let notes = notes
        HStack(spacing: 0) {
            list(notes).frame(width: 248)
            Rectangle().fill(Brand.Palette.hairline).frame(width: 1)
            if let selected, notes.contains(selected) {
                NotePage(note: selected) {
                    self.selected = nil
                    Alerts.shared.attempt("delete the note") { try Workspace(context: context).delete(selected) }
                }
                .id(selected.persistentModelID)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text", description: Text("Pick a note, or start a new one."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Brand.Palette.page)
        .onAppear {
            selected = app.noteToOpen ?? selected ?? notes.first
            app.noteToOpen = nil
        }
        .onChange(of: app.noteToOpen) {
            guard let wanted = app.noteToOpen else { return }
            (selected, search, app.noteToOpen) = (wanted, "", nil)
        }
        // A [[Note title]] link opens that note here.
        .environment(\.openURL, OpenURLAction { url in
            guard let title = NoteLinks.title(from: url) else { return .systemAction }
            Alerts.shared.attempt("open the linked note") {
                guard let target = try Workspace(context: context).note(titled: title) else {
                    throw WorkspaceError.notFound(kind: "note", query: title)
                }
                selected = target
            }
            return .handled
        })
    }

    private func list(_ notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project?.name ?? "Notes").font(Brand.Fonts.title).lineLimit(1)
                Spacer()
                Button("New Note", systemImage: "square.and.pencil") {
                    Alerts.shared.attempt("create the note") {
                        let note = try Workspace(context: context).addNote(title: "Untitled", project: project)
                        withAnimation(AppModel.spring) { selected = note }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.hand)
                .font(.system(size: 15))
                .foregroundStyle(Brand.Palette.accent)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.Palette.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .font(Brand.Fonts.subtitle)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Brand.Palette.field, in: .rect(cornerRadius: 7))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(notes) { note in
                        // Reordering needs the whole list; while searching, a note can still be dragged onto a project.
                        row(note).sortable(.note(note), in: .notes(project), enabled: search.trimmed.isEmpty)
                    }
                    if notes.isEmpty {
                        Text(search.trimmed.isEmpty ? "No notes yet" : "No notes match")
                            .font(Brand.Fonts.subtitle)
                            .foregroundStyle(Brand.Palette.secondary)
                            .padding(.top, 24)
                    }
                }
            }
        }
        .foregroundStyle(Brand.Palette.ink)
        .padding(.horizontal, 12)
        .padding(.top, 48)
    }

    private func row(_ note: Note) -> some View {
        let isSelected = selected == note
        return Button {
            selected = note
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(Brand.Fonts.label)
                    .lineLimit(1)
                Text(snippet(of: note))
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                    .lineLimit(2)
                Text(caption(for: note))
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.Palette.secondary.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Brand.Palette.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The first line of the note that says something, without its Markdown marker.
    private func snippet(of note: Note) -> String {
        // Only the opening of the note is looked at; a long note is not parsed whole for one line.
        for block in NoteMarkdown.blocks(String(note.body.prefix(400))) {
            switch block {
            case .heading(_, let text), .bullet(let text), .checkbox(_, let text), .paragraph(let text): return text
            case .blank: continue
            }
        }
        return "No text yet"
    }

    private func caption(for note: Note) -> String {
        let edited = note.updatedAt.formatted(.relative(presentation: .named))
        guard project == nil, let projectName = note.project?.name else { return edited }
        return "\(projectName) · \(edited)"
    }
}

/// One note: its title over the text. Written as Markdown, read as a formatted page with live checkboxes.
private struct NotePage: View {
    @Bindable var note: Note
    let delete: () -> Void
    @State private var isWriting = true
    @State private var isAttaching = false
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                Spacer()
                Button("Attach File", systemImage: "paperclip") { isAttaching = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.secondary)
                    .help("Attach files to this note")
                modeButton("Write", "pencil", writing: true)
                modeButton("Read", "eye", writing: false)
                Button("Delete Note", systemImage: "trash", role: .destructive, action: delete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.secondary)
            }
            .font(.system(size: 13))
            .padding(.bottom, 14)

            TextField("Title", text: $note.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Brand.Fonts.title)
                .padding(.bottom, 10)
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1).padding(.bottom, 12)
            if !note.sortedAttachments.isEmpty {
                AttachmentList(attachments: note.sortedAttachments).padding(.bottom, 12)
            }

            if isWriting {
                TextEditor(text: $note.body)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(.leading, -5) // the editor insets its text; this lines it up with the title
            } else {
                MarkdownPage(source: $note.body)
            }
            NoteLinksSection(note: note)
        }
        .foregroundStyle(Brand.Palette.ink)
        .padding(.horizontal, 32)
        .padding(.top, 48)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .onChange(of: note.body) { note.updatedAt = .now }
        .fileImporter(isPresented: $isAttaching, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Alerts.shared.attempt("attach the file") { attach(try result.get()) }
        }
        // Files dragged from Finder onto the page are attached too.
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.filter(\.isFileURL))
            return true
        }
        .onAppear { isWriting = note.body.isEmpty }
    }

    private func attach(_ files: [URL]) {
        for file in files {
            Alerts.shared.attempt("attach \(file.lastPathComponent)") {
                try AttachmentStore.shared.attach(fileAt: file, to: note, in: context)
            }
        }
    }

    private func modeButton(_ label: String, _ symbol: String, writing: Bool) -> some View {
        Button(label, systemImage: symbol) {
            withAnimation(.easeOut(duration: 0.15)) { isWriting = writing }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.hand)
        .foregroundStyle(isWriting == writing ? Brand.Palette.accent : Brand.Palette.secondary)
        .help(label)
        .accessibilityAddTraits(isWriting == writing ? .isSelected : [])
    }
}
