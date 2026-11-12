import Foundation

/// The tools that put something to look at in the chat.
extension AgentTools {
    static let showDashboard = AgentTool(
        name: "showDashboard", label: "Show dashboard",
        about: """
            Shows the user a dashboard in the chat. This is the default whenever they ask for an artifact, an overview, a report, \
            their workload, progress or anything "at a glance", without asking for a particular form. You send only the data: \
            headline numbers, charts, an optional table and a few observations. The app draws it, so do not write HTML. Read the \
            real figures with the other tools first; never invent numbers.
            """,
        parameters: [
            Parameter(name: "title", about: "A short title, such as My workload", required: true),
            Parameter(name: "dashboard", about: "The contents of the dashboard", kind: .object(Dashboard.schema), required: true),
        ],
        onDevice: false
    ) { _, input in
        let title = try input.required("title")
        let dashboard = try JSONDecoder().decode(Dashboard.self, from: try JSONEncoder().encode(input.value["dashboard"] ?? .object([:])))
        guard dashboard.kpis?.isEmpty == false || dashboard.charts?.isEmpty == false || dashboard.table != nil else {
            throw AgentToolError.missing("dashboard.kpis, dashboard.charts or dashboard.table")
        }
        return ToolOutcome(text: "The user now sees the dashboard \"\(title)\" in the chat.", page: ChatPage(title: title, html: dashboard.html(title: title)))
    }
}
