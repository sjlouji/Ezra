import SwiftData
import SwiftUI

/// Search and navigation in one field. It first looks at the names of lists, areas, projects and to-dos, and at tags;
/// "Continue Search" widens it to notes, checklists and the Logbook.
struct QuickFindView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    /// Open to-dos; the Logbook's too once the search has been widened.
    private var todos: [ToDo] { isWide ? library.open + library.done : library.open }
    @Query(sort: \Project.order) private var projects: [Project]
    @Query(sort: \Area.order) private var areas: [Area]
    @State private var query = ""
    @State private var isWide = false
    @FocusState private var focused: Bool

    var body: some View {
        let text = query.trimmed
        let matches: (String) -> Bool = { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }
        let todos = todos
        let tags = text.isEmpty ? [] : Set(todos.flatMap(\.tags)).sorted().filter(matches)
        let found = text.isEmpty ? [] : todos.filter { todo in
            guard !todo.isTemplate, isWide || !todo.isCompleted else { return false }
            if matches(todo.title) || todo.tags.contains(where: { $0.localizedCaseInsensitiveCompare(text) == .orderedSame }) { return true }
            return isWide && (matches(todo.notes) || todo.sortedChecklist.contains { matches($0.title) })
        }
        let shownProjects = projects.filter { !$0.isTemplate && matches($0.name) && (isWide || !$0.isCompleted) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Brand.Palette.secondary)
                    TextField(Brand.Words.quickFind, text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Brand.Palette.field, in: .rect(cornerRadius: 9))
                Button("Cancel") { app.setQuickFind(false) }
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.accent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SmartList.allCases.filter { matches($0.title) }) { list in
                        result(.list(list), list.title) { go(.list(list)) }
                    }
                    // Lists that have no place in the sidebar are reached by name.
                    ForEach(SpecialList.allCases.filter { !text.isEmpty && matches($0.rawValue) }) { special in
                        result(special == .repeating ? .list(.anytime) : .list(.upcoming), special.rawValue) { go(.special(special)) }
                    }
                    ForEach(areas.filter { matches($0.name) }) { area in
                        result(.cube, area.name) { go(.area(area)) }
                    }
                    ForEach(shownProjects) { project in
                        result(.pie(progress: project.progress, tint: Brand.Palette.secondary), project.name) { go(.project(project)) }
                    }
                    ForEach(tags, id: \.self) { tag in
                        row(action: { query = tag }) {
                            Image(systemName: "tag").frame(width: 18).foregroundStyle(Brand.Palette.secondary)
                            Text(tag)
                            Spacer()
                            Text("\(todos.count { $0.tags.contains(tag) }) to-dos").foregroundStyle(Brand.Palette.secondary)
                        }
                    }
                    ForEach(found.prefix(40)) { todo in
                        row(action: {
                            app.setQuickFind(false)
                            app.jump(to: todo)
                        }) {
                            CheckBox(checked: todo.isCompleted, size: 13).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(todo.title)
                                if let container = todo.containerName {
                                    Text(container).font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    if !text.isEmpty, !isWide {
                        row(action: { withAnimation(AppModel.spring) { isWide = true } }) {
                            Image(systemName: "magnifyingglass").frame(width: 18).foregroundStyle(Brand.Palette.secondary)
                            Text("Continue Search")
                            Text("in notes, checklists and the Logbook").foregroundStyle(Brand.Palette.secondary)
                            Spacer()
                        }
                    } else if !text.isEmpty, found.isEmpty, shownProjects.isEmpty, tags.isEmpty {
                        Text("No matches for “\(text)”")
                            .foregroundStyle(Brand.Palette.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(Brand.Palette.ink)
        .frame(width: 520, height: 480)
        .background(Brand.Palette.page)
        .onAppear {
            // Opened by typing: start with what was typed.
            query = app.quickFindSeed
            app.quickFindSeed = ""
            focused = true
        }
        .onChange(of: query) { if query.trimmed.isEmpty { isWide = false } }
        // Widening the search is what makes the library start keeping the Logbook.
        .onChange(of: isWide) { if isWide { library.wantDone() } }
        .onExitCommand { app.setQuickFind(false) }
    }

    private func result(_ icon: ListIcon.Kind, _ title: String, action: @escaping () -> Void) -> some View {
        row(action: action) {
            ListIcon(icon, size: 16).frame(width: 18)
            Text(title).fontWeight(.medium)
            Spacer()
        }
    }

    private func row(action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 10) { content() }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .contentShape(.rect)
        }
        .buttonStyle(.hand)
    }

    private func go(_ destination: Destination) {
        app.setQuickFind(false)
        app.destination = destination
    }
}
