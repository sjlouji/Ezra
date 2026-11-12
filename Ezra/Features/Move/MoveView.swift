import SwiftData
import SwiftUI

/// The Move panel: type the name of a list, area, project or heading and press Return to send the to-do there.
struct MoveView: View {
    let todo: ToDo
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.order) private var projects: [Project]
    @Query(sort: \Area.order) private var areas: [Area]
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Place: Identifiable {
        let id: String
        let icon: ListIcon.Kind?
        let symbol: String?
        let title: String
        let target: DropTarget
    }

    var body: some View {
        let places = places()
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right").foregroundStyle(Brand.Palette.secondary)
                TextField("Move “\(todo.title)” to…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if let first = places.first { move(to: first.target) } else { moveToNewProject() }
                    }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Brand.Palette.field, in: .rect(cornerRadius: 9))
            .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(places) { place in
                        Button {
                            move(to: place.target)
                        } label: {
                            HStack(spacing: 9) {
                                if let icon = place.icon {
                                    ListIcon(icon, size: 16)
                                } else {
                                    Image(systemName: place.symbol ?? "circle").frame(width: 16).foregroundStyle(Brand.Palette.secondary)
                                }
                                Text(place.title).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(place.id == places.first?.id ? Brand.Palette.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.hand)
                    }
                    if !query.trimmed.isEmpty {
                        Button("New Project “\(query.trimmed)”", systemImage: "plus", action: moveToNewProject)
                            .buttonStyle(.hand)
                            .foregroundStyle(Brand.Palette.accent)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .font(.system(size: 14.5))
        .foregroundStyle(Brand.Palette.ink)
        .frame(width: 440, height: 380)
        .background(Brand.Palette.page)
        .onAppear { focused = true }
        .onExitCommand { app.moving = nil }
    }

    /// Everywhere the to-do can go, narrowed by what is typed. Headings are offered once something is typed.
    private func places() -> [Place] {
        let text = query.trimmed
        var all: [Place] = []
        if todo.project != nil || todo.area != nil {
            all.append(Place(id: "none", icon: nil, symbol: "xmark", title: "No Project or Area", target: .detached))
        }
        for list in [SmartList.inbox, .today, .anytime, .someday] {
            all.append(Place(id: list.rawValue, icon: .list(list), symbol: nil, title: list.title, target: .list(list)))
        }
        for area in areas {
            all.append(Place(id: "a\(area.uuid)", icon: .cube, symbol: nil, title: area.name, target: .area(area)))
        }
        for project in projects where !project.isCompleted && !project.isTemplate {
            all.append(Place(
                id: "p\(project.uuid)", icon: .pie(progress: project.progress, tint: Brand.Palette.secondary), symbol: nil,
                title: project.name, target: .project(project)
            ))
            guard !text.isEmpty else { continue }
            for heading in project.sortedHeadings {
                all.append(Place(
                    id: "h\(heading.uuid)", icon: nil, symbol: "text.justify.left",
                    title: "\(project.name) › \(heading.title)", target: .heading(heading)
                ))
            }
        }
        return text.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    /// Moves the to-do the panel was opened for, and with it every other to-do picked alongside it.
    private func move(to target: DropTarget) {
        let moved = app.selection.contains(todo) ? app.selection : [todo]
        moved.forEach { app.drop(.todo($0), on: target) }
        app.clearSelection()
        app.moving = nil
    }

    private func moveToNewProject() {
        guard !query.trimmed.isEmpty else { return }
        Alerts.shared.attempt("create the project") {
            move(to: .project(try Workspace(context: context).addProject(name: query)))
        }
    }
}
