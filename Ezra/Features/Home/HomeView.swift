import SwiftData
import SwiftUI

/// The sidebar: the lists, then projects and areas, over "New List" and settings.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Area.order) private var areas: [Area]
    @Query(sort: \Project.order) private var projects: [Project]
    @Environment(Library.self) private var library
    /// The project or area a right-click asked to delete, until the user has confirmed.
    @State private var deleting: Doomed?

    var body: some View {
        // Counted once per save by the library, not on every pass through here.
        let (inbox, today, due) = (library.inbox, library.today, library.due)
        return VStack(spacing: 0) {
            // The window's own buttons and the sidebar switch sit here; the list scrolls below them, never under them.
            Color.clear.frame(height: 38)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    listRow(.inbox, count: inbox)
                    gap
                    listRow(.today, pill: due, count: today)
                    listRow(.upcoming)
                    listRow(.anytime)
                    listRow(.someday)
                    gap
                    listRow(.logbook)
                    gap
                    SidebarRow(symbol: "calendar.day.timeline.left", title: "Planner", destination: .planner)
                    SidebarRow(symbol: "sparkles", title: Brand.assistant, destination: .assistant)

                    let loose = projects.filter { $0.area == nil && !$0.isCompleted && !$0.isTemplate }
                    if !loose.isEmpty { gap }
                    ForEach(loose, content: projectRow)
                    ForEach(areas) { area in
                        gap
                        SidebarRow(icon: .cube, title: area.name, bold: true, destination: .area(area))
                            .contextMenu { menu(for: area) }
                            .dropTarget(.area(area))
                            .sortable(.area(area), in: .areas)
                        ForEach(area.sortedProjects, content: projectRow)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
            footer
        }
        .background(Brand.Palette.sidebar)
        .confirmationDialog(deleting?.question ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { delete(deleting) } }
        } message: {
            Text(deleting?.consequence ?? "")
        }
    }

    private var gap: some View { Color.clear.frame(height: 14) }

    private var footer: some View {
        HStack {
            Menu {
                Button("New Project") {
                    Alerts.shared.attempt("create the project") {
                        app.destination = .project(try Workspace(context: context).addProject(name: "New Project"))
                    }
                }
                let blueprints = projects.filter(\.isBlueprint)
                if !blueprints.isEmpty {
                    Menu("New Project from Template") {
                        ForEach(blueprints) { blueprint in
                            Button(blueprint.name) {
                                Alerts.shared.attempt("create the project") {
                                    app.destination = .project(try Workspace(context: context).stampOut(blueprint))
                                }
                            }
                        }
                    }
                }
                Button("New Area") {
                    Alerts.shared.attempt("create the area") {
                        app.destination = .area(try Workspace(context: context).addArea(name: "New Area"))
                    }
                }
            } label: {
                Label("New List", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(Brand.Palette.secondary)
            .pointerStyle(.link)
            Spacer()
            Button(Brand.Words.settings, systemImage: "slider.horizontal.3") { openSettings() }
                .help("Settings (⌘,)")
                .labelStyle(.iconOnly)
                .buttonStyle(.hand)
        }
        .font(.system(size: 14))
        .foregroundStyle(Brand.Palette.secondary)
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func listRow(_ list: SmartList, pill: Int = 0, count: Int = 0) -> some View {
        SidebarRow(icon: .list(list), title: list.title, pill: pill, count: count, destination: .list(list))
            .contextMenu {
                if list != .logbook {
                    Button("New To-Do in \(list.title)") {
                        app.destination = .list(list)
                        app.create(AppModel.Placement(schedule: list.newToDoSchedule()))
                    }
                }
                if list == .inbox { Button("New Note in \(list.title)") { app.destination = .list(list); app.newNote() } }
            }
            .dropTarget(.list(list))
    }

    private func projectRow(_ project: Project) -> some View {
        SidebarRow(
            icon: .pie(progress: project.progress, tint: Brand.Palette.secondary), title: project.name, destination: .project(project)
        )
        .contextMenu { menu(for: project) }
        .dropTarget(.project(project))
        .sortable(.project(project), in: .projects(project.area))
    }
}

/// Right-click menus of the sidebar's projects and areas.
extension HomeView {
    fileprivate enum Doomed {
        case project(Project), area(Area)

        var question: String {
            switch self {
            case .project(let project): "Delete “\(project.name)” with its to-dos and notes?"
            case .area(let area): "Delete the area “\(area.name)”?"
            }
        }
        var consequence: String {
            switch self {
            case .project: "This cannot be undone."
            case .area: "Its projects, to-dos and notes are kept, without an area."
            }
        }
    }

    private var workspace: Workspace { Workspace(context: context) }

    @ViewBuilder
    fileprivate func menu(for project: Project) -> some View {
        Button("New To-Do") {
            app.destination = .project(project)
            app.create(AppModel.Placement(project: project))
        }
        Button("New Note") { app.destination = .project(project); app.newNote() }
        Button("New Heading") {
            app.destination = .project(project)
            Alerts.shared.attempt("add the heading") { try workspace.addHeading(title: "New Heading", to: project) }
        }
        Divider()
        Button(project.isCompleted ? "Reopen Project" : "Complete Project") {
            Alerts.shared.attempt("update the project") { try workspace.setCompleted(project, !project.isCompleted) }
        }
        Menu("Move to Area") {
            Button("No Area") { Alerts.shared.attempt("move the project") { project.area = nil; try context.save() } }
            ForEach(areas) { area in
                Button(area.name) { Alerts.shared.attempt("move the project") { project.area = area; try context.save() } }
            }
        }
        if !project.isBlueprint {
            Button("Save as Template") { Alerts.shared.attempt("save the template") { try workspace.saveAsTemplate(project) } }
        }
        Divider()
        Button("Delete Project…", role: .destructive) { deleting = .project(project) }
    }

    @ViewBuilder
    fileprivate func menu(for area: Area) -> some View {
        Button("New Project in \(area.name)") {
            Alerts.shared.attempt("create the project") { app.destination = .project(try workspace.addProject(name: "New Project", area: area)) }
        }
        Button("New To-Do") {
            app.destination = .area(area)
            app.create(AppModel.Placement(area: area))
        }
        Button("New Note") { app.destination = .area(area); app.newNote() }
        Divider()
        Button("Delete Area…", role: .destructive) { deleting = .area(area) }
    }

    fileprivate func delete(_ doomed: Doomed) {
        deleting = nil
        // Leave the screen of what is about to go.
        switch (doomed, app.destination) {
        case (.project(let project), .project(let open)) where project == open: app.destination = .list(.today)
        case (.area(let area), .area(let open)) where area == open: app.destination = .list(.today)
        default: break
        }
        switch doomed {
        case .project(let project): Alerts.shared.attempt("delete the project") { try workspace.delete(project) }
        case .area(let area): Alerts.shared.attempt("delete the area") { try workspace.delete(area) }
        }
    }
}

/// One sidebar entry; the one for the open screen sits on a soft grey highlight.
private struct SidebarRow: View {
    var icon: ListIcon.Kind?
    var symbol: String?
    let title: String
    var bold = false
    /// To-dos due today or overdue, shown in a red pill.
    var pill = 0
    var count = 0
    let destination: Destination
    @Environment(AppModel.self) private var app

    var body: some View {
        let isSelected = app.destination == destination
        Button {
            app.closeCard()
            app.destination = destination
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    ListIcon(icon, size: 16)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.Palette.secondary)
                        .frame(width: 16)
                }
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.system(size: 14.5, weight: bold ? .bold : .regular))
                    .foregroundStyle(Brand.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if pill > 0 {
                    Text("\(pill)")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Brand.Palette.todayPill, in: .capsule)
                        .accessibilityLabel("\(pill) due")
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.Palette.secondary)
                }
            }
            .padding(.vertical, 4.5)
            .padding(.horizontal, 8)
            .background(isSelected ? Brand.Palette.sidebarSelected : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
