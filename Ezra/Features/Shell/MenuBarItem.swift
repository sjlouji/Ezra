import SwiftData
import SwiftUI

/// What sits in the Mac's menu bar: how many to-dos are left today.
struct MenuBarLabel: View {
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }

    var body: some View {
        let left = todos.count { SmartList.today.contains($0) }
        Label(left == 0 ? "" : "\(left)", systemImage: left == 0 ? "checkmark.circle" : "circle")
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("\(Brand.name): \(left) to-dos left today")
    }
}

/// The panel under the menu bar item: add a to-do without opening the window, and tick off today's.
struct MenuBarPanel: View {
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let today = todos.filter { SmartList.today.contains($0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(Brand.Palette.secondary)
                TextField("New to-do for today", text: $title)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(add)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Brand.Palette.field, in: .rect(cornerRadius: 7))
            if today.isEmpty {
                Text("Nothing left for today.").foregroundStyle(Brand.Palette.secondary).padding(.vertical, 4)
            }
            ForEach(today.prefix(8)) { todo in
                HStack(spacing: 8) {
                    Button {
                        Alerts.shared.attempt("complete the to-do") { try Workspace(context: context).setCompleted(todo, true) }
                    } label: {
                        CheckBox(checked: false)
                    }
                    .help("Mark as done")
                    Text(todo.title).lineLimit(1).foregroundStyle(Brand.Palette.ink)
                    Spacer(minLength: 0)
                    if let days = todo.daysToDeadline(), days <= 0 {
                        Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Brand.Palette.deadline)
                    }
                }
            }
            if today.count > 8 {
                Text("and \(today.count - 8) more").foregroundStyle(Brand.Palette.secondary)
            }
            Divider()
            HStack {
                Button("Open \(Brand.name)") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .foregroundStyle(Brand.Palette.accent)
        }
        .font(Brand.Fonts.subtitle)
        .buttonStyle(.hand)
        .padding(12)
        .frame(width: 290)
        .onAppear { titleFocused = true }
    }

    private func add() {
        guard !title.trimmed.isEmpty else { return }
        Alerts.shared.attempt("add the to-do") {
            try Workspace(context: context).addToDo(title: title, schedule: .on(.now))
            title = ""
        }
    }
}
