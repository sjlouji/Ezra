import SwiftData
import SwiftUI

/// A project: its description, loose to-dos and notes, then each heading with its to-dos and notes.
struct ProjectView: View {
    @Bindable var project: Project
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Area.order) private var areas: [Area]
    @State private var showsCompleted = false
    @State private var confirmsDelete = false
    @State private var tag: String?

    private var workspace: Workspace { Workspace(context: context) }

    @ViewBuilder
    private var menuItems: some View {
        Button("Add Heading") {
            Alerts.shared.attempt("add the heading") { try workspace.addHeading(title: "New Heading", to: project) }
        }
        Button(project.isCompleted ? "Reopen Project" : "Complete Project") {
            Alerts.shared.attempt("update the project") { try workspace.setCompleted(project, !project.isCompleted) }
        }
        Menu("Move to Area") {
            Button("No Area") { project.area = nil }
            ForEach(areas) { area in
                Button(area.name) { project.area = area }
            }
        }
        if project.templateUUID == nil, !project.isTemplate {
            Button("Repeat…") {
                Alerts.shared.attempt("make the project repeat") { try workspace.setRepeat(project, RepeatRule(unit: .month)) }
            }
        }
        if !project.isBlueprint {
            Button("Save as Template") {
                Alerts.shared.attempt("save the template") {
                    try workspace.saveAsTemplate(project)
                    app.destination = .special(.templates)
                }
            }
        } else {
            Button("New Project from This Template") {
                Alerts.shared.attempt("create the project") { app.destination = .project(try workspace.stampOut(project)) }
            }
        }
        Button("New Note") { app.newNote() }
        Divider()
        Button("Delete Project…", role: .destructive) { confirmsDelete = true }
    }

    var body: some View {
        let tags = Set((project.tasks ?? []).flatMap(\.tags)).sorted()
        let open = project.openTasks.filter { tag == nil || $0.tags.contains(tag ?? "") }
        let completed = project.completedTasks
        // Notes carry no tags, so they step aside while the list is filtered by one.
        let notes = tag == nil ? (project.notes ?? []).inOrder : []
        ScreenList {
            HStack(spacing: 10) {
                ListIcon(.pie(progress: project.progress, tint: Brand.Palette.accent), size: 23)
                TextField("New Project", text: $project.name)
                    .font(Brand.Fonts.title)
                    .foregroundStyle(Brand.Palette.ink)
                    .fixedSize()
                TitleMenu { menuItems }
                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .plainRow()
            MarkdownEditor(text: $project.details, placeholder: Brand.Words.notes, fontSize: 14)
                .plainRow(top: 8, bottom: 12)
            if let rule = project.repeatRule {
                RepeatEditor(rule: rule) { changed in
                    Alerts.shared.attempt("change the repeat") { try workspace.setRepeat(project, changed) }
                }
                .plainRow(bottom: 12)
            }
            if !tags.isEmpty {
                TagFilterBar(tags: tags, selection: $tag).plainRow()
            }

            ToDoRows(todos: open.filter { $0.heading == nil }, showsContainer: false, showsWhen: true, section: .project(project))
            NoteRows(notes: notes.filter { $0.heading == nil }, group: project.persistentModelID)
            ForEach(project.sortedHeadings) { heading in
                HeadingRow(heading: heading).sortable(.heading(heading), in: .headings(project)).dropTarget(.heading(heading)).plainRow(bottom: 4)
                ToDoRows(todos: open.filter { $0.heading == heading }, showsContainer: false, showsWhen: true, section: .heading(heading))
                NoteRows(notes: notes.filter { $0.heading == heading }, group: heading.persistentModelID)
            }
            if !completed.isEmpty {
                Button(showsCompleted ? "Hide completed to-dos" : Brand.Words.showCompleted(completed.count)) {
                    withAnimation(AppModel.spring) { showsCompleted.toggle() }
                }
                .buttonStyle(.hand)
                .font(Brand.Fonts.label)
                .foregroundStyle(Brand.Palette.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Brand.Palette.field, in: .capsule)
                .plainRow(top: 22, bottom: 6)
                if showsCompleted {
                    ToDoRows(todos: completed, style: .logbook, showsContainer: false)
                }
            }
        }
        .textFieldStyle(.plain)
        .confirmationDialog("Delete “\(project.name)” with its to-dos and notes?", isPresented: $confirmsDelete) {
            Button("Delete Project", role: .destructive) {
                app.destination = .list(.today)
                Alerts.shared.attempt("delete the project") { try workspace.delete(project) }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

private struct HeadingRow: View {
    @Bindable var heading: Heading
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Heading", text: $heading.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.Palette.accent)
                Menu {
                    // Its to-dos stay in the project, without a heading.
                    Button("Delete Heading", role: .destructive) { context.delete(heading) }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Brand.Palette.accent)
                        .accessibilityLabel("Heading options")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Rectangle().fill(Brand.Palette.accent.opacity(0.25)).frame(height: 1)
        }
        .padding(.top, 26)
    }
}

/// An area: its projects with their open counts, then the to-dos filed directly under it.
struct AreaView: View {
    @Bindable var area: Area
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var confirmsDelete = false

    var body: some View {
        ScreenList {
            HStack(spacing: 10) {
                ListIcon(.cube, size: 23)
                TextField("New Area", text: $area.name)
                    .font(Brand.Fonts.title)
                    .foregroundStyle(Brand.Palette.ink)
                    .fixedSize()
                TitleMenu {
                    Button("New Project") {
                        Alerts.shared.attempt("create the project") {
                            app.destination = .project(try Workspace(context: context).addProject(name: "New Project", area: area))
                        }
                    }
                    Button("New Note") { app.newNote() }
                    Divider()
                    Button("Delete Area…", role: .destructive) { confirmsDelete = true }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .padding(.bottom, 14)
            .plainRow()
            ForEach(area.sortedProjects) { project in
                HStack(spacing: 10) {
                    ListIcon(.pie(progress: project.progress, tint: Brand.Palette.secondary), size: 15)
                    Text(project.name).font(Brand.Fonts.rowBold)
                    Spacer()
                    Text("\(project.openTasks.count)")
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.secondary)
                }
                .padding(.vertical, 7)
                .contentShape(.rect)
                .onTapGesture { app.destination = .project(project) }
                .pointerStyle(.link)
                .accessibilityAddTraits(.isButton)
                .plainRow()
            }
            if !area.openToDos.isEmpty {
                Rectangle().fill(Brand.Palette.hairline).frame(height: 1).plainRow(top: 10, bottom: 6)
            }
            ToDoRows(todos: area.openToDos, showsContainer: false, showsWhen: true)
            NoteRows(notes: (area.notes ?? []).inOrder, group: area.persistentModelID)
        }
        .textFieldStyle(.plain)
        .confirmationDialog("Delete the area “\(area.name)”?", isPresented: $confirmsDelete) {
            Button("Delete Area", role: .destructive) {
                app.destination = .list(.today)
                Alerts.shared.attempt("delete the area") { try Workspace(context: context).delete(area) }
            }
        } message: {
            Text("Its projects, to-dos and notes are kept, without an area.")
        }
    }
}
