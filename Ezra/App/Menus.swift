import SwiftData
import SwiftUI

extension FocusedValues {
    /// The front window's navigation state, so the menu bar acts on that window.
    @Entry var appModel: AppModel?
}

/// The menu bar: File (new items), Edit (Quick Find), View (sidebar, Go To), Items (the open to-do) and Window (Quick Entry).
/// Every keyboard command of the window lives here, so each is listed with its shortcut and exists only once.
struct EzraCommands: Commands {
    @FocusedValue(\.appModel) private var app

    private var todo: ToDo? { app?.card?.todo }
    private var workspace: Workspace? { app?.context.map { Workspace(context: $0) } }
    private var project: Project? {
        if case .project(let project) = app?.destination { project } else { nil }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New To-Do") { app?.newToDo() }.keyboardShortcut("n")
            Button("New Note") { app?.newNote() }
            Button("New Heading") {
                guard let project, let workspace else { return }
                Alerts.shared.attempt("add the heading") { try workspace.addHeading(title: "New Heading", to: project) }
            }
            .disabled(project == nil)
            Button("New Project") {
                Alerts.shared.attempt("create the project") {
                    guard let workspace else { return }
                    app?.destination = .project(try workspace.addProject(name: "New Project"))
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Area") {
                Alerts.shared.attempt("create the area") {
                    guard let workspace else { return }
                    app?.destination = .area(try workspace.addArea(name: "New Area"))
                }
            }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("\(Brand.Words.quickFind)…") { app?.setQuickFind(true) }.keyboardShortcut("f")
        }
        CommandGroup(replacing: .sidebar) {
            Button(app?.sidebarHidden == true ? "Show Sidebar" : "Hide Sidebar") {
                if let app { app.setSidebar(hidden: !app.sidebarHidden) }
            }
            .keyboardShortcut("/")
            Divider()
            Menu("Go To") {
                ForEach(Array(SmartList.allCases.enumerated()), id: \.element) { index, list in
                    Button(list.title) { go(.list(list)) }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Planner") { go(.planner) }.keyboardShortcut("7")
                Button(Brand.assistant) { go(.assistant) }.keyboardShortcut("j")
            }
            Button("Back") { app?.goBack() }.keyboardShortcut("[").disabled(app?.canGoBack != true)
            Button("Forward") { app?.goForward() }.keyboardShortcut("]").disabled(app?.canGoForward != true)
            Divider()
        }
        CommandMenu("Items") {
            // These act on the to-do that is open.
            Group {
                item("\(Brand.Words.when)…", "s") { app?.pick(.when, for: $0) }
                item("Move…", "m", [.command, .shift]) { app?.moving = $0 }
                item("Deadline…", "d", [.command, .shift]) { app?.pick(.deadline, for: $0) }
                Divider()
                item(SmartList.today.title, "t") { plan($0, .on(.now)) }
                item(Brand.Words.thisEvening, "e") { plan($0, .on(.now, evening: true)) }
                item(SmartList.anytime.title, "r") { plan($0, .anytime) }
                item(SmartList.someday.title, "o") { plan($0, .someday) }
                Divider()
                item("Complete", "k") { todo in
                    Alerts.shared.attempt("complete the to-do") { try workspace?.setCompleted(todo, true) }
                    app?.closeCard()
                }
                Divider()
                Button("Remove From Project") {
                    guard let todo else { return }
                    Alerts.shared.attempt("move the to-do") { try workspace?.move(todo, to: nil) }
                }
                .disabled(todo?.project == nil)
                Button("Show in Project") {
                    guard let todo, let home = todo.project else { return }
                    app?.closeCard()
                    app?.destination = .project(home)
                    app?.open(todo)
                }
                .keyboardShortcut("l")
                .disabled(todo?.project == nil)
                Divider()
                Button("Delete To-Do") {
                    guard let todo else { return }
                    app?.closeCard()
                    Alerts.shared.attempt("delete the to-do") { try workspace?.delete(todo) }
                }
            }
            .disabled(todo == nil)
        }
        CommandGroup(before: .windowList) {
            Button("Quick Entry") { QuickEntry.shared.toggle() }
            Divider()
        }
    }

    private func go(_ destination: Destination) {
        app?.closeCard()
        app?.destination = destination
    }

    private func item(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command, action: @escaping (ToDo) -> Void) -> some View {
        Button(title) { if let todo { action(todo) } }.keyboardShortcut(key, modifiers: modifiers)
    }

    private func plan(_ todo: ToDo, _ schedule: Schedule) {
        Alerts.shared.attempt("reschedule the to-do") {
            try withAnimation(AppModel.spring) { try workspace?.schedule(todo, schedule) }
        }
    }
}
