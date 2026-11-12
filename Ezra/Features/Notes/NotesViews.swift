import SwiftData
import SwiftUI

/// One note, open as a page: where it lives, its title, then the text in the block editor. Under it, the to-dos it is attached to.
struct NoteScreen: View {
    @Bindable var note: Note
    @State private var isAttaching = false
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Query(sort: \Project.order) private var projects: [Project]
    @Query(sort: \Area.order) private var areas: [Area]

    /// The list the note is in.
    private var home: Destination {
        note.project.map(Destination.project) ?? note.area.map(Destination.area) ?? .list(.inbox)
    }

    /// Leaves the page: back to where the user came from, else to the list the note is in.
    private func leave() {
        if app.canGoBack { app.goBack() } else { app.destination = home }
    }

    private func delete() {
        let workspace = Workspace(context: context)
        leave()
        Alerts.shared.attempt("delete the note") { try workspace.delete(note) }
    }

    @ViewBuilder
    private var moveItems: some View {
        let workspace = Workspace(context: context)
        Button(SmartList.inbox.title) { Alerts.shared.attempt("move the note") { try workspace.move(note, to: nil) } }
        Divider()
        ForEach(areas) { area in
            Button(area.name) { Alerts.shared.attempt("move the note") { try workspace.move(note, to: nil, area: area) } }
        }
        Divider()
        ForEach(projects.filter { !$0.isCompleted && !$0.isTemplate }) { project in
            Button(project.name) { Alerts.shared.attempt("move the note") { try workspace.move(note, to: project) } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button(action: leave) {
                    Label(note.containerName ?? SmartList.inbox.title, systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(.hand)
                .foregroundStyle(Brand.Palette.accent)
                .keyboardShortcut(.cancelAction)
                .help("Back")
                Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                Spacer()
                Menu { moveItems } label: {
                    Image(systemName: "arrow.right").accessibilityLabel("Move note")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Brand.Palette.secondary)
                .help("Move this note to a project, an area or the Inbox")
                Button("Attach File", systemImage: "paperclip") { isAttaching = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.secondary)
                    .help("Attach files to this note")
                Button("Delete Note", systemImage: "trash", role: .destructive, action: delete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.secondary)
            }
            .font(.system(size: 14))
            .padding(.bottom, 14)

            TextField("Title", text: $note.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Brand.Fonts.title)
                .padding(.bottom, 10)
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1).padding(.bottom, 12)
            if !note.sortedAttachments.isEmpty {
                AttachmentList(attachments: note.sortedAttachments).padding(.bottom, 12)
            }

            // The handles hang in the margin, so the text itself lines up with the title.
            BlockEditor(markdown: $note.body).padding(.leading, -BlockEditor.gutter)
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
        .background(Brand.Palette.page)
        // A [[Note title]] link opens that note.
        .environment(\.openURL, OpenURLAction { url in
            guard let title = NoteLinks.title(from: url) else { return .systemAction }
            Alerts.shared.attempt("open the linked note") {
                guard let target = try Workspace(context: context).note(titled: title) else {
                    throw WorkspaceError.notFound(kind: "note", query: title)
                }
                app.destination = .note(target)
            }
            return .handled
        })
    }

    private func attach(_ files: [URL]) {
        for file in files {
            Alerts.shared.attempt("attach \(file.lastPathComponent)") {
                try AttachmentStore.shared.attach(fileAt: file, to: note, in: context)
            }
        }
    }
}
