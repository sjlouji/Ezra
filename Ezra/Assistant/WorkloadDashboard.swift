import Foundation

extension Dashboard.Loose {
    init(_ text: String) { self.text = text }
    init(_ number: Int) { text = String(number) }
}

extension Dashboard {
    /// The user's workload, worked out from the store: no model supplies or can get wrong a single figure.
    @MainActor
    static func workload(todos all: [ToDo], projects allProjects: [Project], now: Date = .now, calendar: Calendar = .current) -> Dashboard {
        let today = calendar.startOfDay(for: now)
        let week = SmartList.day(7, from: now, calendar: calendar)
        let weekAgo = SmartList.day(-6, from: now, calendar: calendar)
        let todos = all.filter { !$0.isTemplate && $0.project?.isTemplate != true }
        let open = todos.filter { !$0.isCompleted }
        let overdue = open.filter { $0.deadline.map { $0 < today } ?? false }
        let dueSoon = open.filter { $0.deadline.map { $0 >= today && $0 < week } ?? false }
        let doneLately = todos.filter { $0.completedAt.map { $0 >= weekAgo } ?? false }
        let projects = allProjects.filter { !$0.isTemplate && !$0.isCompleted }

        let byProject = projects.map { ($0.name, $0.openTasks.count) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        var byArea: [String: Int] = [:]
        for todo in open { byArea[todo.project?.area?.name ?? todo.area?.name ?? "No area", default: 0] += 1 }
        let days = (0..<7).map { SmartList.day($0 - 6, from: now, calendar: calendar) }
        let completedPerDay = days.map { day in
            Item(label: day.formatted(.dateTime.weekday(.abbreviated)), value: Loose(doneLately.count { $0.completedAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false }))
        }
        let progress = projects.filter { !($0.tasks ?? []).isEmpty }.sorted { $0.openTasks.count > $1.openTasks.count }.prefix(6)
            .map { Item(label: $0.name, value: Loose(Int(($0.progress * 100).rounded()))) }
        let deadlines = open.filter { $0.deadline != nil }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }.prefix(8)

        var notes: [String] = []
        if let busiest = byProject.first { notes.append("\(busiest.0) holds the most open work (\(busiest.1) to-dos).") }
        if !overdue.isEmpty { notes.append("\(overdue.count) to-do\(overdue.count == 1 ? " is" : "s are") past the deadline: \(overdue.prefix(2).map(\.title).joined(separator: ", "))\(overdue.count > 2 ? " and more" : "").") }
        let inbox = open.count { $0.when == .inbox }
        if inbox > 0 { notes.append("\(inbox) to-do\(inbox == 1 ? "" : "s") in the Inbox still need a place.") }
        let planned = open.count { SmartList.today.contains($0, now: now, calendar: calendar) }
        notes.append(planned == 0 ? "Nothing is planned for today." : "\(planned) planned for today.")

        return Dashboard(
            subtitle: "Open work across your projects and areas",
            kpis: [
                KPI(label: "Open to-dos", value: Loose(open.count), note: "\(planned) on Today"),
                KPI(label: "Due this week", value: Loose(dueSoon.count)),
                KPI(label: "Overdue", value: Loose(overdue.count), note: overdue.isEmpty ? "Nothing late" : "Needs attention", tone: overdue.isEmpty ? "good" : "bad"),
                KPI(label: "Done this week", value: Loose(doneLately.count), tone: doneLately.isEmpty ? nil : "good"),
            ],
            charts: [
                Chart(title: "Open by project", type: "bar", items: byProject.prefix(8).map { Item(label: $0.0, value: Loose($0.1)) }),
                Chart(title: "Open by area", type: "donut", items: byArea.sorted { $0.value > $1.value }.map { Item(label: $0.key, value: Loose($0.value)) }),
                Chart(title: "Completed, last 7 days", type: "line", items: completedPerDay),
                Chart(title: "Project progress", type: "progress", items: Array(progress)),
            ].filter { !$0.items.isEmpty },
            table: deadlines.isEmpty ? nil : Table(
                title: "Next deadlines", columns: ["To-do", "Project", "Due", "Days left"],
                rows: deadlines.map { todo in
                    [Loose(todo.title), Loose(todo.project?.name ?? todo.area?.name ?? ""),
                     Loose(todo.deadline?.formatted(.dateTime.month(.abbreviated).day()) ?? ""), Loose(todo.daysToDeadline(now: now, calendar: calendar) ?? 0)]
                }
            ),
            notes: notes
        )
    }

    /// The figures in a few lines, for the model to speak from.
    var summary: String {
        ((kpis ?? []).map { "\($0.label): \($0.value.text)" } + (notes ?? [])).joined(separator: "\n")
    }
}

extension AgentTools {
    static let showWorkload = AgentTool(
        name: "showWorkload", label: "Show workload",
        about: """
            Shows the user a dashboard of their own workload: open, due, overdue and completed to-dos, by project and area, with \
            the next deadlines. The app works out every figure itself, so call this (with no arguments) whenever they ask for \
            their workload, an overview of their to-dos or projects, or "an artifact" about their work, instead of reading the lists yourself.
            """,
        parameters: []
    ) { workspace, _ in
        let dashboard = Dashboard.workload(todos: try workspace.allToDos(), projects: try workspace.projects())
        return ToolOutcome(
            text: "The user now sees their workload dashboard. Its figures:\n\(dashboard.summary)",
            page: ChatPage(title: "My workload", html: dashboard.html(title: "My workload"))
        )
    }
}
