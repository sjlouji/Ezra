import AppIntents
import SwiftData

/// "Add To-Do" in the Shortcuts app, for Siri, automations and any agent that can run a shortcut.
struct AddToDoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add To-Do"
    static let description = IntentDescription("Adds a to-do to Ezra, optionally with a day, notes and a list.")

    @Parameter(title: "Title")
    var todoTitle: String

    @Parameter(title: "When", description: "For example: today, evening, tomorrow 2pm, fri, in 3 days, someday")
    var when: String?

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "List", description: "Inbox, Today, Anytime, Someday, or the name of a project or area")
    var list: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try EzraStore.shared ?? EzraStore.makeContainer()
        var command = AddCommand(title: todoTitle)
        (command.when, command.notes, command.list) = (when.nonEmpty, notes ?? "", list.nonEmpty)
        let todo = try command.run(in: Workspace(context: container.mainContext))
        return .result(dialog: "Added “\(todo.title)”.")
    }
}

struct EzraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddToDoIntent(), phrases: ["Add a to-do in \(.applicationName)"], shortTitle: "Add To-Do", systemImageName: "plus")
    }
}
