import SwiftData
import SwiftUI

/// Several to-dos picked at once: ⌘-click adds or removes one, ⇧-click picks everything between.
extension AppModel {
    func isSelected(_ todo: ToDo) -> Bool { selection.contains(todo) }

    func toggleSelection(_ todo: ToDo) {
        closeCard()
        if let index = selection.firstIndex(of: todo) { selection.remove(at: index) } else { selection.append(todo) }
    }

    /// Picks every row of `run` from the last one picked to `todo`. With nothing picked yet, just `todo`.
    func extendSelection(to todo: ToDo, in run: [ToDo]) {
        closeCard()
        guard let anchor = selection.last, let from = run.firstIndex(of: anchor), let to = run.firstIndex(of: todo) else {
            if !selection.contains(todo) { selection.append(todo) }
            return
        }
        for picked in run[min(from, to)...max(from, to)] where !selection.contains(picked) { selection.append(picked) }
        // The row clicked becomes the new end to extend from.
        selection.removeAll { $0 == todo }
        selection.append(todo)
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
    }

    /// Runs one change on every picked to-do, then lets go of them.
    func applyToSelection(_ what: String, _ change: (Workspace, ToDo) throws -> Void) {
        guard let context else { return Log.store.error("Selection used before the store was attached") }
        Alerts.shared.attempt(what) {
            let workspace = Workspace(context: context)
            try withAnimation(Self.spring) {
                for todo in selection { try change(workspace, todo) }
            }
            selection = []
        }
    }
}

extension Workspace {
    /// Adds a tag to a to-do unless it has it already.
    func addTag(_ tag: String, to todo: ToDo) throws {
        try edit(todo, tags: todo.tags + [tag])
    }
}

/// Takes the bottom toolbar's place while to-dos are picked: what can be done to all of them at once.
struct SelectionBar: View {
    @Environment(AppModel.self) private var app
    @State private var tagging = false
    @State private var tag = ""
    @State private var confirmsDelete = false

    var body: some View {
        let count = app.selection.count
        HStack(spacing: 14) {
            Text("\(count) selected").font(Brand.Fonts.label).foregroundStyle(Brand.Palette.ink)
            Group {
                Button("Today") { app.applyToSelection("schedule the to-dos") { try $0.schedule($1, .on(.now)) } }
                Button(Brand.Words.tomorrow) { app.applyToSelection("schedule the to-dos") { try $0.schedule($1, .on(SmartList.day(1))) } }
                Button("Someday") { app.applyToSelection("schedule the to-dos") { try $0.schedule($1, .someday) } }
                Button("Tag…") { tagging = true }
                    .popover(isPresented: $tagging, arrowEdge: .top) {
                        TextField("Tag for all \(count)", text: $tag)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .padding(10)
                            .onSubmit {
                                let wanted = tag.trimmed
                                guard !wanted.isEmpty else { return }
                                (tag, tagging) = ("", false)
                                app.applyToSelection("tag the to-dos") { try $0.addTag(wanted, to: $1) }
                            }
                    }
                Button("Move…") { app.moving = app.selection.first }
                Button("Complete") { app.applyToSelection("complete the to-dos") { try $0.setCompleted($1, true) } }
                Button("Delete…", role: .destructive) { confirmsDelete = true }
            }
            .font(Brand.Fonts.subtitle)
            .foregroundStyle(Brand.Palette.accent)
            Button("Clear Selection", systemImage: "xmark") { app.clearSelection() }
                .labelStyle(.iconOnly)
                .foregroundStyle(Brand.Palette.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Clear the selection (Esc)")
        }
        .buttonStyle(.hand)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .confirmationDialog("Delete \(count) to-do\(count == 1 ? "" : "s")?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { app.applyToSelection("delete the to-dos") { try $0.delete($1) } }
        } message: {
            Text("This cannot be undone.")
        }
    }
}
