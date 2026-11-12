import Foundation

/// Every tool the assistant has. Reading tools are here; the ones that change data are in AgentChangeTools.swift.
enum AgentTools {
    typealias Parameter = AgentTool.Parameter

    static let all: [AgentTool] = [
        listTasks, listProjects, listAreasAndTags, search, listNotes, readNote, listEvents, showTasks, showWorkload, showDashboard, showPage, buildArtifact, dateMath, plan, setTimer, notify, delegate,
        addTask, updateTask, completeTask, addProject, addArea, writeNote, attachNote, addEvent, remember,
    ]

    /// One to-do as the model reads it.
    @MainActor
    static func line(for task: ToDo) -> String {
        var parts = ["- \(task.title)"]
        if let project = task.project { parts.append("[project: \(project.name)]") }
        if let area = task.area { parts.append("[area: \(area.name)]") }
        if task.when == .someday { parts.append("[someday]") }
        if let when = task.startDate { parts.append("[when: \(DayText.string(day: when))\(task.evening ? " evening" : "")]") }
        if !task.tags.isEmpty { parts.append("[tags: \(task.tags.joined(separator: ", "))]") }
        if let deadline = task.deadline { parts.append("[deadline: \(DayText.string(day: deadline))]") }
        if let reminder = task.reminderAt { parts.append("[reminder: \(DayText.string(moment: reminder))]") }
        if task.isCompleted { parts.append("[done]") }
        return parts.joined(separator: " ")
    }

    static func capped(_ lines: [String], limit: Int = 30) -> String {
        guard lines.count > limit else { return lines.joined(separator: "\n") }
        return (lines.prefix(limit) + ["…and \(lines.count - limit) more."]).joined(separator: "\n")
    }

    private static let lists = ["open", "inbox", "today", "upcoming", "anytime", "someday", "logbook"]

    @MainActor
    private static func tasks(in workspace: Workspace, list: String?, project: String?) throws -> [ToDo] {
        var tasks = try workspace.tasks(in: list.flatMap { SmartList(rawValue: $0.lowercased()) })
        if let project {
            let found = try workspace.findProject(project)
            tasks = tasks.filter { $0.project == found }
        }
        return tasks
    }

    static let listTasks = AgentTool(
        name: "listTasks", label: "Read to-dos",
        about: "Lists the user's tasks in one list, optionally only those of one project.",
        parameters: [
            Parameter(name: "list", about: "The list to read", required: true, options: lists),
            Parameter(name: "project", about: "A project name to limit to; omit for all projects"),
        ]
    ) { workspace, input in
        let found = try tasks(in: workspace, list: input.string("list"), project: input.string("project"))
        return ToolOutcome(text: found.isEmpty ? "No tasks." : capped(found.map(line)))
    }

    static let listProjects = AgentTool(
        name: "listProjects", label: "Read projects",
        about: "Lists the user's projects with their area, deadline and task counts.",
        parameters: [Parameter(name: "includeCompleted", about: "true to include completed projects too", kind: .flag)]
    ) { workspace, input in
        let includeCompleted = input.bool("includeCompleted")
        let projects = try workspace.projects().filter { !$0.isTemplate && (includeCompleted || !$0.isCompleted) }
        let lines = projects.map { project in
            var parts = ["- \(project.name)"]
            if let area = project.area { parts.append("[area: \(area.name)]") }
            if let deadline = project.deadline { parts.append("[deadline: \(DayText.string(day: deadline))]") }
            parts.append("[open tasks: \(project.openTasks.count), done: \(project.completedTasks.count)]")
            if project.isCompleted { parts.append("[completed]") }
            return parts.joined(separator: " ")
        }
        return ToolOutcome(text: lines.isEmpty ? "No projects." : capped(lines))
    }

    static let listAreasAndTags = AgentTool(
        name: "listAreasAndTags", label: "Read areas and tags",
        about: "Lists the user's areas and every tag in use.",
        parameters: [], onDevice: false
    ) { workspace, _ in
        let areas = try workspace.areas().map(\.name)
        let tags = try workspace.allTags()
        return ToolOutcome(text: """
            Areas: \(areas.isEmpty ? "none" : areas.joined(separator: ", "))
            Tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))
            """)
    }

    static let search = AgentTool(
        name: "search", label: "Search",
        about: "Finds open tasks, projects and notes whose text contains a word or phrase.",
        parameters: [Parameter(name: "query", about: "The word or phrase to look for", required: true)]
    ) { workspace, input in
        let query = try input.required("query").trimmed
        let tasks = try workspace.tasks().filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let projects = try workspace.projects().filter { $0.name.localizedCaseInsensitiveContains(query) }
        let notes = try workspace.notes().filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
        }
        let lines = tasks.map(line) + projects.map { "- Project: \($0.name)" } + notes.map { "- Note: \($0.title)" }
        return ToolOutcome(text: lines.isEmpty ? "Nothing matches \"\(query)\"." : capped(lines), todos: tasks.map(\.uuid))
    }

    static let readNote = AgentTool(
        name: "readNote", label: "Read note",
        about: "Returns the text of one note.",
        parameters: [Parameter(name: "title", about: "The note's title", required: true)]
    ) { workspace, input in
        let note = try workspace.findNote(try input.required("title"))
        // The on-device model's context is small; a long note is cut rather than failing the turn.
        let limit = 3000
        let body = note.body.count > limit ? note.body.prefix(limit) + "\n…(note continues)" : note.body
        return ToolOutcome(text: "# \(note.title)\n\(body.isEmpty ? "(empty)" : body)")
    }

    static let listEvents = AgentTool(
        name: "listEvents", label: "Read calendar",
        about: "Lists the calendar events of one day, with their times.",
        parameters: [Parameter(name: "day", about: "The day: today, tomorrow, or a date as yyyy-MM-dd", required: true)]
    ) { workspace, input in
        let day = try DayText.day(from: try input.required("day"))
        let events = Planner.events(on: day, from: try workspace.events())
        guard !events.isEmpty else { return ToolOutcome(text: "No events on \(DayText.string(day: day)).") }
        let lines = events.map { event in
            let time = event.isAllDay
                ? "all day" : "\(DayText.string(moment: event.start).suffix(5))–\(DayText.string(moment: event.end).suffix(5))"
            return "- \(time) \(event.title)"
        }
        return ToolOutcome(text: lines.joined(separator: "\n"))
    }

    static let showTasks = AgentTool(
        name: "showTasks", label: "Show table",
        about: """
            Shows the user a table of to-dos in the chat. Each row links to its to-do and can be checked off or rescheduled there. \
            Use it whenever the answer is a set of to-dos, instead of writing them out. Give a list, a project, or both.
            """,
        parameters: [
            Parameter(name: "title", about: "A short heading for the table", required: true),
            Parameter(name: "list", about: "The list to show; omit when a project is given", options: lists),
            Parameter(name: "project", about: "A project name to limit to; omit for all projects"),
            Parameter(name: "tag", about: "Only to-dos with this tag; omit for all"),
        ]
    ) { workspace, input in
        var found = try tasks(in: workspace, list: input.string("list"), project: input.string("project"))
        if let tag = input.string("tag") {
            found = found.filter { $0.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
        }
        guard !found.isEmpty else { return ToolOutcome(text: "No tasks match, so no table was shown.") }
        let table = ChatTable(title: try input.required("title"), todos: found.map(\.uuid))
        return ToolOutcome(text: "The user now sees a table of these \(found.count) to-dos:\n\(capped(found.map(line)))", table: table)
    }

    static let showPage = AgentTool(
        name: "showPage", label: "Make page",
        about: """
            Shows the user an interactive page in the chat, written by you as HTML: a chart, a timeline, a board, a dashboard, a calculator. \
            Use it when a picture or something to click explains better than text. The page must be complete and self-contained: \
            inline CSS and JavaScript, inline SVG or canvas for graphics, the data written into it. It cannot load anything from the \
            network (no CDN scripts, fonts or images) and cannot call tools or any API. Read the data with the other tools first, then \
            write the values into the page as literals. Design it for a white background about 620 points wide, with system fonts.
            """,
        parameters: [
            Parameter(name: "title", about: "A short heading for the page", required: true),
            Parameter(name: "html", about: "The whole HTML document", required: true),
        ],
        onDevice: false
    ) { _, input in
        let page = ChatPage(title: try input.required("title"), html: try input.required("html"))
        // A page that tries to load its data shows nothing, so it is sent back to the model with the reason.
        if let loader = ["fetch(", "XMLHttpRequest", "src=\"http", "src='http", "href=\"http", "@import"].first(where: page.html.contains) {
            throw AgentToolError.pageLoadsData(loader)
        }
        return ToolOutcome(text: "The user now sees the page \"\(page.title)\" in the chat.", page: page)
    }

    static let buildArtifact = AgentTool(
        name: "buildArtifact", label: "Build artifact",
        about: """
            Builds an interactive artifact in the chat from one React component file you write: a dashboard, a planner board, a \
            calculator, a chart with controls. Prefer it over showPage whenever the result has state, several parts or real UI components.

            Stack: React 18 with hooks, TypeScript, Tailwind CSS classes, shadcn/ui, lucide-react icons, Recharts. Write a single \
            file with a default-exported component. You may import only: react; lucide-react; recharts; @/lib/utils (cn); and \
            @/components/ui/<name>, where <name> is one of: \(ArtifactKit.components.joined(separator: ", ")).

            It cannot load anything: no fetch, no network, no other files. Read the data with the other tools first and write the \
            values into the code as constants. Design it for a light page about 620 points wide.

            Design: avoid the generic AI look. No centred hero layouts, no purple gradients, no identical rounded cards everywhere, \
            no Inter font. Use a clear hierarchy, dense useful information, and one accent colour used sparingly.
            """,
        parameters: [
            Parameter(name: "title", about: "A short heading for the artifact", required: true),
            Parameter(name: "code", about: "The whole component file, TSX", required: true),
        ],
        onDevice: false
    ) { _, input in
        let code = try input.required("code")
        try ArtifactKit.check(code)
        let page = ChatPage(title: try input.required("title"), html: "", code: code)
        return ToolOutcome(text: "The user now sees the artifact \"\(page.title)\" in the chat.", page: page)
    }

    static let dateMath = AgentTool(
        name: "dateMath", label: "Work out a date",
        about: "Works out dates exactly: the weekday of a date, the date a number of days away, or the days between two dates. Use it instead of counting days yourself.",
        parameters: [
            Parameter(name: "date", about: "The starting date: today, tomorrow, or yyyy-MM-dd", required: true),
            Parameter(name: "addDays", about: "A whole number of days to add (negative to go back); omit to add none"),
            Parameter(name: "until", about: "A second date as yyyy-MM-dd, to count the days from the first to it; omit if not needed"),
        ],
        onDevice: false
    ) { _, input in
        let calendar = Calendar.current
        let start = try DayText.day(from: try input.required("date"))
        func named(_ day: Date) -> String { "\(day.formatted(.dateTime.weekday(.wide))) \(DayText.string(day: day))" }
        var lines = ["\(named(start))"]
        if let text = input.string("addDays") {
            guard let days = Int(text), let moved = calendar.date(byAdding: .day, value: days, to: start) else { throw WorkspaceError.badDate(text) }
            lines.append("\(days) days from it is \(named(moved))")
        }
        if let text = input.string("until") {
            let end = try DayText.day(from: text)
            lines.append("\(calendar.dateComponents([.day], from: start, to: end).day ?? 0) days from it to \(named(end))")
        }
        return ToolOutcome(text: lines.joined(separator: ". "))
    }

    static let plan = AgentTool(
        name: "plan", label: "Plan",
        about: """
            Shows the user a short checklist of the steps you are working through, for a request with several parts. Call it once with \
            the steps before you start, and again with what is done as you finish them. Not for the user's own to-dos: those are tasks.
            """,
        parameters: [
            Parameter(name: "steps", about: "Every step, in order, a few words each", kind: .list, required: true),
            Parameter(name: "done", about: "The steps finished so far, written exactly as in steps; omit when none", kind: .list),
        ],
        onDevice: false
    ) { _, input in
        let done = Set(input.strings("done").map { $0.lowercased() })
        let lines = input.strings("steps").map { PlanLine(title: $0, done: done.contains($0.lowercased())) }
        return ToolOutcome(text: "The user sees the plan: \(lines.count { $0.done }) of \(lines.count) done.", plan: lines)
    }

    // The next three are carried out by the chat itself (see `ChatModel.extras`); described here so models are offered them.

    static let setTimer = AgentTool(
        name: "setTimer", label: "Set timer",
        about: "Starts a timer. When it ends the user is notified and, if a prompt was given, that prompt is sent into this chat for you to act on.",
        parameters: [
            Parameter(name: "minutes", about: "How long, in minutes, as a number", required: true),
            Parameter(name: "label", about: "What it is for, a few words", required: true),
            Parameter(name: "prompt", about: "What to do when it ends, as a message to you; omit for a plain timer"),
        ],
        changesData: true, onDevice: false
    ) { _, _ in throw AgentToolError.unavailable("setTimer") }

    static let notify = AgentTool(
        name: "notify", label: "Notify",
        about: "Shows the user a notification on their Mac right now. Use it when asked to, or when something they are waiting for is ready.",
        parameters: [
            Parameter(name: "title", about: "A few words", required: true),
            Parameter(name: "message", about: "One sentence", required: true),
        ],
        onDevice: false
    ) { _, _ in throw AgentToolError.unavailable("notify") }

    static let delegate = AgentTool(
        name: "delegate", label: "Ask sub-agents",
        about: """
            Hands focused pieces of work to sub-agents that run at the same time, each with your tools, and returns what each found. \
            Use it when a request splits into independent parts (several things to research or compare). Give each a complete, self-contained task.
            """,
        parameters: [Parameter(name: "tasks", about: "One complete task per sub-agent, at most four", kind: .list, required: true)],
        onDevice: false
    ) { _, _ in throw AgentToolError.unavailable("delegate") }
}
