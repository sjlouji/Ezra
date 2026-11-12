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

    var body: some View {
        // Counted once per save by the library, not on every pass through here.
        let (inbox, today, due) = (library.inbox, library.today, library.due)
        return VStack(spacing: 0) {
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
                    SidebarRow(symbol: "note.text", title: "Notes", destination: .notes(nil))
                        .dropTarget(.allNotes)
                    SidebarRow(symbol: "sparkles", title: Brand.assistant, destination: .assistant)

                    let loose = projects.filter { $0.area == nil && !$0.isCompleted && !$0.isTemplate }
                    if !loose.isEmpty { gap }
                    ForEach(loose, content: projectRow)
                    ForEach(areas) { area in
                        gap
                        SidebarRow(icon: .cube, title: area.name, bold: true, destination: .area(area))
                            .dropTarget(.area(area))
                            .sortable(.area(area), in: .areas)
                        ForEach(area.sortedProjects, content: projectRow)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 48) // clear of the window's close, minimise and zoom buttons
                .padding(.bottom, 12)
            }
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
            footer
        }
        .background(Brand.Palette.sidebar)
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
        .font(.system(size: 13))
        .foregroundStyle(Brand.Palette.secondary)
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func listRow(_ list: SmartList, pill: Int = 0, count: Int = 0) -> some View {
        SidebarRow(icon: .list(list), title: list.title, pill: pill, count: count, destination: .list(list))
            .dropTarget(.list(list))
    }

    private func projectRow(_ project: Project) -> some View {
        SidebarRow(
            icon: .pie(progress: project.progress, tint: Brand.Palette.secondary), title: project.name, destination: .project(project)
        )
        .dropTarget(.project(project))
        .sortable(.project(project), in: .projects(project.area))
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
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.Palette.secondary)
                        .frame(width: 16)
                }
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.system(size: 13.5, weight: bold ? .bold : .regular))
                    .foregroundStyle(Brand.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if pill > 0 {
                    Text("\(pill)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Brand.Palette.todayPill, in: .capsule)
                        .accessibilityLabel("\(pill) due")
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12))
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
