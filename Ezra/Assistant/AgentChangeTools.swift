import Foundation

/// The tools that change the user's data.
extension AgentTools {
    private static let whenWords = "today, tonight, tomorrow, someday, or a date as yyyy-MM-dd"

    static let addTask = AgentTool(
        name: "addTask", label: "Add to-do",
        about: "Creates a task, with a reminder when a time is given. Without a project or area it goes to the Inbox.",
        parameters: [
            Parameter(name: "title", about: "The task's title", required: true),
            Parameter(name: "notes", about: "Notes for the task, as Markdown; omit for none"),
            Parameter(name: "project", about: "Name of an existing project to put it in; omit for none"),
            Parameter(name: "area", about: "Name of an area to put it in when there is no project; omit for none", onDevice: false),
            Parameter(name: "when", about: "When to do it: \(whenWords); omit if not said"),
            Parameter(name: "deadline", about: "Due date as yyyy-MM-dd; omit if not said"),
            Parameter(name: "reminder", about: "Reminder time as yyyy-MM-dd HH:mm (24-hour), exactly the time the user said: 9 pm is 21:00. Omit if no time was said"),
            Parameter(
                name: "tags", about: "One to three tags that fit the task. Reuse the user's existing tags where one fits.",
                kind: .list, required: true
            ),
            Parameter(name: "checklist", about: "Steps inside the task; omit for none", kind: .list, onDevice: false),
        ],
        changesData: true
    ) { workspace, input in
        // Resolve every argument before creating anything, so a bad one creates nothing.
        let project = try input.string("project").map(workspace.findProject)
        let area = try input.string("area").map(workspace.area(named:))
        // Small models muddle the two date arguments (a time in "when", words in "reminder"); what they meant is still clear.
        let (planned, reminder) = try timing(when: input.string("when"), reminder: input.string("reminder"))
        var schedule = planned ?? .unscheduled
        // A reminder with no day said still means that day.
        if schedule == .unscheduled, let reminder { schedule = .on(Calendar.current.startOfDay(for: reminder)) }
        let task = try workspace.addToDo(
            title: try input.required("title"),
            notes: input.string("notes") ?? "",
            project: project, area: area, schedule: schedule,
            deadline: try input.string("deadline").map { try DayText.day(from: $0) },
            reminderAt: reminder,
            tags: Workspace.tidied(input.strings("tags"))
        )
        try workspace.addChecklist(input.strings("checklist"), to: task)
        return ToolOutcome(text: "Added task \(line(for: task).dropFirst(2))", todos: [task.uuid])
    }

    /// The plan and the reminder two date arguments amount to. A date with a time given as "when" is a reminder on that
    /// day; a reminder given as a bare time belongs to the planned day (or today); a reminder that is not a time at all
    /// is dropped when the time is known from "when", and refused otherwise.
    static func timing(when: String?, reminder: String?, now: Date = .now, calendar: Calendar = .current) throws -> (Schedule?, Date?) {
        var schedule: Schedule?
        var moment: Date?
        if let when {
            if let exact = try? DayText.moment(from: when) {
                (schedule, moment) = (.on(calendar.startOfDay(for: exact)), exact)
            } else {
                schedule = try DayText.schedule(from: when)
            }
        }
        if let reminder {
            if let exact = try? DayText.moment(from: reminder) {
                moment = exact
            } else if let minutes = try? DayText.minutes(from: reminder) {
                let day: Date = if case .on(let planned, _) = schedule { planned } else { calendar.startOfDay(for: now) }
                moment = day.addingTimeInterval(TimeInterval(minutes) * 60)
            } else if moment == nil {
                throw WorkspaceError.badDate(reminder)
            }
        }
        return (schedule, moment)
    }

    static let updateTask = AgentTool(
        name: "updateTask", label: "Change to-do",
        about: "Changes an open task: its status, title, notes, tags, plan, deadline, reminder, project or area. Only the given fields change.",
        parameters: [
            Parameter(name: "title", about: "The task's title, as listed", required: true),
            Parameter(name: "status", about: "done to complete it, open to reopen it; omit to keep", options: ["done", "open"]),
            Parameter(name: "newTitle", about: "A new title; omit to keep", onDevice: false),
            Parameter(name: "notes", about: "New notes, replacing the old; omit to keep", onDevice: false),
            Parameter(name: "tags", about: "The full new set of tags; omit to keep", kind: .list),
            Parameter(name: "when", about: "New plan: \(whenWords), or none; omit to keep"),
            Parameter(name: "deadline", about: "New due date as yyyy-MM-dd; omit to keep"),
            Parameter(name: "reminder", about: "New reminder time as yyyy-MM-dd HH:mm; omit to keep"),
            Parameter(name: "project", about: "Name of an existing project to move it to; omit to keep"),
            Parameter(name: "area", about: "Name of an area to move it to; omit to keep", onDevice: false),
        ],
        changesData: true
    ) { workspace, input in
        let wanted = try input.required("title")
        // A task being reopened is in the Logbook, so look there too.
        let task = try input.string("status") == "open"
            ? Workspace.uniqueMatch(in: try workspace.allToDos(), kind: "task", query: wanted, name: \.title)
            : workspace.findToDo(wanted)
        let newProject = try input.string("project").map(workspace.findProject)
        let newArea = try input.string("area").map(workspace.area(named:))
        let (newSchedule, newReminder) = try timing(when: input.string("when"), reminder: input.string("reminder"))
        let newDeadline = try input.string("deadline").map { try DayText.day(from: $0) }
        let newTags = input.value["tags"] == nil ? nil : input.strings("tags")

        try workspace.edit(task, title: input.string("newTitle"), notes: input.string("notes"), tags: newTags)
        if let newProject, task.project != newProject { try workspace.move(task, to: newProject) }
        if newProject == nil, let newArea { try workspace.move(task, to: nil, area: newArea) }
        if let newDeadline { try workspace.setDeadline(task, newDeadline) }
        if let newSchedule { try workspace.schedule(task, newSchedule) }
        if let newReminder { try workspace.setReminder(task, at: newReminder) }
        if let status = input.string("status") { try workspace.setCompleted(task, status == "done") }
        return ToolOutcome(text: "Updated task \(line(for: task).dropFirst(2))", todos: [task.uuid])
    }

    static let completeTask = AgentTool(
        name: "completeTask", label: "Complete to-do",
        about: "Marks one open task as done.",
        parameters: [Parameter(name: "title", about: "The task's title, as listed", required: true)],
        changesData: true
    ) { workspace, input in
        let task = try workspace.findToDo(try input.required("title"))
        try workspace.setCompleted(task, true)
        return ToolOutcome(text: "Completed task \(task.title)", todos: [task.uuid])
    }

    static let addProject = AgentTool(
        name: "addProject", label: "Add project",
        about: "Creates a project, optionally inside an area (created when it does not exist), with notes and its first tasks.",
        parameters: [
            Parameter(name: "name", about: "The project's name", required: true),
            Parameter(name: "area", about: "Area to put it in; omit for none"),
            Parameter(name: "notes", about: "What the project is about, as Markdown; omit for none", onDevice: false),
            Parameter(name: "tasks", about: "Titles of the tasks to create inside it, in order; omit for none", kind: .list),
        ],
        changesData: true
    ) { workspace, input in
        let project = try workspace.addProject(
            name: try input.required("name"), area: try input.string("area").map(workspace.area(named:))
        )
        if let notes = input.string("notes") { try workspace.setDetails(project, notes) }
        let tasks = try input.strings("tasks").map { try workspace.addToDo(title: $0, project: project) }
        var text = "Created project \(project.name)" + (project.area.map { " in area \($0.name)" } ?? "")
        if !tasks.isEmpty { text += " with \(tasks.count) tasks" }
        return ToolOutcome(text: text, todos: tasks.map(\.uuid))
    }

    static let addArea = AgentTool(
        name: "addArea", label: "Add area",
        about: "Creates an area: a part of life or work that holds projects and tasks, such as Work or Family.",
        parameters: [Parameter(name: "name", about: "The area's name", required: true)],
        changesData: true, onDevice: false
    ) { workspace, input in
        let name = try input.required("name")
        let existed = try workspace.areas().contains { $0.name.localizedCaseInsensitiveCompare(name.trimmed) == .orderedSame }
        let area = try workspace.area(named: name)
        return ToolOutcome(text: existed ? "The area \(area.name) already exists." : "Created area \(area.name)")
    }

    static let writeNote = AgentTool(
        name: "writeNote", label: "Write note",
        about: "Adds Markdown text to the note with this title, creating the note when there is none. Use it to save ideas, plans and research.",
        parameters: [
            Parameter(name: "title", about: "The note's title", required: true),
            Parameter(name: "text", about: "The Markdown text to add", required: true),
            Parameter(name: "project", about: "For a new note: name of an existing project to file it under; omit for none"),
        ],
        changesData: true
    ) { workspace, input in
        let (title, text) = (try input.required("title").trimmed, try input.required("text"))
        if let existing = try workspace.notes().first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            try workspace.append(text, to: existing)
            return ToolOutcome(text: "Added to note \(existing.title)")
        }
        let note = try workspace.addNote(title: title, body: text, project: try input.string("project").map(workspace.findProject))
        return ToolOutcome(text: "Created note \(note.title)")
    }

    static let remember = AgentTool(
        name: "remember", label: "Remember",
        about: """
            Saves one lasting fact or preference about the user (how they like to plan, who people are, recurring constraints) so it \
            is known in every future chat. Use it when the user states such a thing or asks you to remember it; not for tasks.
            """,
        parameters: [Parameter(name: "fact", about: "The fact, as one short sentence", required: true)],
        changesData: true, onDevice: false
    ) { workspace, input in
        try workspace.remember(try input.required("fact"))
        return ToolOutcome(text: "Remembered. The user can read and edit this in the note \"\(Workspace.memoryTitle)\".")
    }

    static let addEvent = AgentTool(
        name: "addEvent", label: "Add event",
        about: "Puts an event (a meeting, call or appointment with a time) on the user's calendar.",
        parameters: [
            Parameter(name: "title", about: "The event's title", required: true),
            Parameter(name: "day", about: "The day: today, tomorrow, or a date as yyyy-MM-dd", required: true),
            Parameter(name: "start", about: "Start time in 24-hour HH:mm, for example 14:30", required: true),
            Parameter(name: "end", about: "End time in 24-hour HH:mm; omit for a one-hour event"),
        ],
        changesData: true
    ) { workspace, input in
        let day = try DayText.day(from: try input.required("day"))
        let start = day.addingTimeInterval(TimeInterval(try DayText.minutes(from: try input.required("start"))) * 60)
        let end = try input.string("end").map { day.addingTimeInterval(TimeInterval(try DayText.minutes(from: $0)) * 60) }
        let event = try workspace.addEvent(title: try input.required("title"), start: start, end: end)
        return ToolOutcome(
            text: "Added event \(event.title) on \(DayText.string(moment: event.start)) to \(DayText.string(moment: event.end).suffix(5))"
        )
    }
}
