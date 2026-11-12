import SwiftData
import SwiftUI

/// The saved conversations: pinned first, searchable, each with pin, rename and delete.
struct ChatHistory: View {
    let model: ChatModel
    @Environment(AppModel.self) private var app
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @State private var query = ""
    @State private var renaming: ChatThread?
    @State private var newTitle = ""
    @State private var deleting: ChatThread?
    @State private var filing: ChatThread?
    @State private var newFolder = ""

    /// Conversations whose title or any message contains the search text.
    private var matches: [ChatThread] {
        let wanted = query.trimmed
        guard !wanted.isEmpty else { return threads }
        return threads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(wanted)
                || (thread.messages ?? []).contains { $0.text.localizedCaseInsensitiveContains(wanted) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.Palette.secondary)
                TextField("Search chats", text: $query).textFieldStyle(.plain)
            }
            .font(Brand.Fonts.subtitle)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Brand.Palette.field, in: .rect(cornerRadius: 7))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let pinned = matches.filter(\.pinned)
                    // While a chat is dragged, both headers show, as the places to drop it to pin or unpin.
                    let draggingChat = if case .chat = app.drag?.item { true } else { false }
                    if !pinned.isEmpty || draggingChat {
                        header("Pinned").frame(maxWidth: .infinity, alignment: .leading).dropTarget(.chats(pinned: true))
                        ForEach(pinned) { row($0) }
                        header("Chats").frame(maxWidth: .infinity, alignment: .leading).dropTarget(.chats(pinned: false))
                    }
                    // Filed chats under their folders, then the rest.
                    let loose = matches.filter { !$0.pinned }
                    ForEach(Set(loose.map(\.folder)).filter { !$0.isEmpty }.sorted(), id: \.self) { folder in
                        header(folder, symbol: "folder")
                        ForEach(loose.filter { $0.folder == folder }) { row($0) }
                    }
                    if loose.contains(where: { !$0.folder.isEmpty }), loose.contains(where: \.folder.isEmpty) { header("Chats") }
                    ForEach(loose.filter(\.folder.isEmpty)) { row($0) }
                    if matches.isEmpty {
                        Text(threads.isEmpty ? "No chats yet." : "No chat matches.")
                            .font(Brand.Fonts.subtitle)
                            .foregroundStyle(Brand.Palette.secondary)
                            .padding(8)
                    }
                }
            }
        }
        .padding(10)
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let renaming { model.rename(renaming, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: Binding(get: { filing != nil }, set: { if !$0 { filing = nil } })) {
            TextField("Folder name", text: $newFolder)
            Button("Move") { if let filing, !newFolder.trimmed.isEmpty { model.move(filing, toFolder: newFolder) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) { if let deleting { model.delete(deleting) } }
        } message: {
            Text("It is removed from every device. This cannot be undone.")
        }
    }

    private func header(_ title: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(title.uppercased())
        }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Brand.Palette.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ thread: ChatThread) -> some View {
        ChatHistoryRow(
            thread: thread, selected: model.thread == thread,
            open: { model.open(thread) },
            pin: { model.togglePin(thread) },
            delete: { deleting = thread }
        )
        // Draggable onto the Pinned and Chats headers; chats keep their newest-first order, so they do not reorder.
        .sortable(.chat(thread), in: .areas, enabled: false)
        .contextMenu {
            Button(thread.pinned ? "Unpin" : "Pin") { model.togglePin(thread) }
            Button("Rename…") {
                newTitle = thread.title
                renaming = thread
            }
            Menu("Move to Folder") {
                ForEach(Set(threads.map(\.folder)).filter { !$0.isEmpty }.sorted(), id: \.self) { folder in
                    Button(folder) { model.move(thread, toFolder: folder) }
                }
                Button("New Folder…") {
                    newFolder = ""
                    filing = thread
                }
                if !thread.folder.isEmpty {
                    Divider()
                    Button("Take Out of “\(thread.folder)”") { model.move(thread, toFolder: "") }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = thread }
        }
        .disabled(model.isResponding)
    }
}

private struct ChatHistoryRow: View {
    let thread: ChatThread
    let selected: Bool
    let open: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title.isEmpty ? "Untitled" : thread.title)
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.ink)
                        .lineLimit(1)
                    Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.hand)
            if hovered || thread.pinned {
                Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.fill" : "pin", action: pin)
                    .help(thread.pinned ? "Unpin this chat" : "Pin this chat to the top")
            }
            if hovered {
                Button("Delete", systemImage: "trash", action: delete).help("Delete this chat")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.hand)
        .font(.system(size: 11))
        .foregroundStyle(Brand.Palette.secondary)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? Brand.Palette.sidebarSelected : .clear, in: .rect(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}
