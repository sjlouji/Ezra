import SwiftData
import SwiftUI

/// The Inbox: a flat list of the to-dos and notes not yet filed anywhere.
struct InboxView: View {
    @Environment(Library.self) private var library
    private var all: [ToDo] { library.open }
    @Query(sort: \Note.order) private var allNotes: [Note]

    var body: some View {
        let inbox = all.filter { SmartList.inbox.contains($0) }
        let notes = allNotes.filter(\.isInInbox).inOrder
        ScreenList {
            ScreenTitle(icon: .list(.inbox), title: SmartList.inbox.title).plainRow()
            if inbox.isEmpty && notes.isEmpty {
                EmptyRow(text: "Your Inbox is empty").plainRow()
            }
            ToDoRows(todos: inbox, showsContainer: false, showsWhen: true)
            NoteRows(notes: notes)
        }
    }
}

/// Anytime and Someday: to-dos under the project or area they belong to.
struct GroupedListView: View {
    let list: SmartList
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    private var all: [ToDo] { library.open }
    @Query(sort: \Project.order) private var projects: [Project]
    @Query(sort: \Area.order) private var areas: [Area]

    private struct Group: Identifiable {
        let id: PersistentIdentifier
        let icon: ListIcon.Kind
        let title: String
        let destination: Destination
        /// What a to-do dropped on this group joins.
        let target: DropTarget
        let todos: [ToDo]
    }

    var body: some View {
        let todos = all.filter { list.contains($0) }
        ScreenList {
            ScreenTitle(icon: .list(list), title: list.title).plainRow()
            if todos.isEmpty {
                EmptyRow(text: "Nothing in \(list.title)").plainRow()
            }
            ToDoRows(todos: todos.filter { $0.project == nil && $0.area == nil }, showsContainer: false, showsWhen: true, section: .detached)
            ForEach(groups(of: todos)) { group in
                GroupHeader(icon: group.icon, title: group.title) { app.destination = group.destination }
                    .dropTarget(group.target)
                    .plainRow(bottom: 2)
                ToDoRows(todos: group.todos, showsContainer: false, showsWhen: true, section: group.target)
            }
        }
    }

    /// Projects without an area first, then each area followed by its projects; only those with to-dos here.
    private func groups(of todos: [ToDo]) -> [Group] {
        // Sorted into their projects and areas in one pass, instead of searching the list once per project.
        let inProject = Dictionary(grouping: todos.filter { $0.project != nil }) { $0.project?.persistentModelID }
        let inArea = Dictionary(grouping: todos.filter { $0.project == nil && $0.area != nil }) { $0.area?.persistentModelID }
        func group(for project: Project) -> Group? {
            guard let its = inProject[project.persistentModelID] else { return nil }
            return Group(
                id: project.persistentModelID, icon: .pie(progress: project.progress, tint: Brand.Palette.accent),
                title: project.name, destination: .project(project), target: .project(project), todos: its
            )
        }
        var groups = projects.filter { $0.area == nil }.compactMap(group)
        for area in areas {
            if let its = inArea[area.persistentModelID] {
                groups.append(Group(id: area.persistentModelID, icon: .cube, title: area.name, destination: .area(area), target: .area(area), todos: its))
            }
            groups += projects.filter { $0.area == area }.compactMap(group)
        }
        return groups
    }
}
