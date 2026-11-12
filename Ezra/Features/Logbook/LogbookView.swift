import SwiftData
import SwiftUI

/// Completed to-dos, newest first: Today, Yesterday, the rest of the week by day, then by month.
struct LogbookView: View {
    @Environment(Library.self) private var library
    /// How many completed to-dos are loaded. The list starts with one page and takes another as its end scrolls into view.
    @State private var limit = LogbookView.page
    static let page = 100
    @Environment(\.modelContext) private var context
    @State private var confirmsClear = false

    private struct Group: Identifiable {
        let id: String
        var todos: [ToDo]
    }

    var body: some View {
        // Fetched here, a page at a time, and again whenever something has been saved.
        let _ = library.revision
        let loaded = Result { (todos: try library.completed(limit: limit), total: try library.completedCount()) }
        let (todos, total) = (try? loaded.get()) ?? ([], 0)
        let groups = groups(of: todos)
        ScreenList {
            ScreenTitle(icon: .list(.logbook), title: SmartList.logbook.title) {
                Button("Clear Logbook…", role: .destructive) { confirmsClear = true }
                    .disabled(groups.isEmpty)
            }
            .plainRow()
            if case .failure(let error) = loaded {
                Label("The Logbook could not be read: \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.Palette.deadline)
                    .plainRow()
            } else if groups.isEmpty {
                EmptyRow(text: "Completed to-dos appear here").plainRow()
            }
            ForEach(groups) { group in
                GroupHeader(icon: nil, title: group.id).plainRow(bottom: 2)
                ToDoRows(todos: group.todos, style: .logbook)
            }
            if total > todos.count {
                Text("Showing \(todos.count.formatted()) of \(total.formatted())")
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .plainRow()
                    // This row exists only once the list has been scrolled to its end: the moment to fetch the next page.
                    .onAppear { limit += Self.page }
            }
        }
        .confirmationDialog("Permanently delete every completed to-do?", isPresented: $confirmsClear) {
            Button("Clear Logbook", role: .destructive) {
                Alerts.shared.attempt("clear the Logbook") { try Workspace(context: context).clearLogbook() }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// `done` is newest first, as the database returned it.
    private func groups(of done: [ToDo]) -> [Group] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var groups: [Group] = []
        for todo in done {
            let day = calendar.startOfDay(for: todo.completedAt ?? .now)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let title =
                switch daysAgo {
                case ...0: "Today"
                case 1: "Yesterday"
                case 2...6: day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                default: day.formatted(.dateTime.month(.wide))
                }
            if groups.last?.id == title {
                groups[groups.count - 1].todos.append(todo)
            } else {
                groups.append(Group(id: title, todos: [todo]))
            }
        }
        return groups
    }
}
