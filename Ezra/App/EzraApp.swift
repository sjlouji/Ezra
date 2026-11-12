import SwiftData
import SwiftUI

@main
struct EzraApp: App {
    private let store: Result<ModelContainer, Error>
    private let sync: SyncEngine?
    @AppStorage("menubar.shown") private var showsMenuBarItem = true
    /// One assistant for the main window and the Settings window.
    private let chat: ChatModel?
    private let widgets: WidgetFeed?
    private let automations: AutomationRunner?
    /// The to-dos, fetched once for the window and the menu bar alike.
    private let library: Library?

    init() {
        do {
            // A load test runs on a made-up store of its own: nothing is synced, and the widgets and automations stay on the real data.
            if LoadTest.requested > 0 {
                try LoadTest.removeStore()
                let container = try EzraStore.makeContainer(named: LoadTest.storeName)
                let made = try LoadTest.fill(container.mainContext, todos: LoadTest.requested)
                LoadTest.active = made.todos
                Log.store.info("Load test: \(made.todos) to-dos, \(made.projects) projects, \(made.notes) notes, \(made.events) events")
                store = .success(container)
                EzraStore.shared = container
                // For trying the Claude connection end to end: on this made-up data only, with a token given at launch.
                if let token = UserDefaults.standard.string(forKey: "MCPTestToken"), !token.isEmpty {
                    let port = UserDefaults.standard.integer(forKey: "MCPTestPort")
                    MCPServer.shared.start(container: container, port: port > 0 ? port : MCPServer.defaultPort + 1, token: token)
                }
                chat = ChatModel(container: container)
                library = Library(context: container.mainContext)
                (sync, widgets, automations) = (nil, nil, nil)
                return
            }
            let container = try EzraStore.makeContainer()
            store = .success(container)
            EzraStore.shared = container
            sync = SyncEngine(container: container)
            chat = ChatModel(container: container)
            library = Library(context: container.mainContext)
            widgets = WidgetFeed(container: container)
            widgets?.start()
            automations = AutomationRunner { ChatModel(container: container) }
            automations?.start()
            sync?.start()
            MCPServer.shared.apply(container: container)
            QuickEntry.shared.install()
            do {
                try Seeder.prepare(context: container.mainContext)
                try Workspace(context: container.mainContext).generateRepeats()
            } catch {
                Alerts.shared.report("prepare the demo data", error)
            }
        } catch {
            Log.store.error("Opening the store failed: \(String(describing: error), privacy: .public)")
            store = .failure(error)
            (sync, chat, widgets, automations, library) = (nil, nil, nil, nil, nil)
        }
    }

    var body: some Scene {
        Window(Brand.name, id: "main") {
            switch store {
            case .success(let container):
                RootView(container: container, chat: chat, library: library)
                    .modelContainer(container)
                    .environment(sync)
                    .onAppear { DockIcon.start() }
            case .failure(let error):
                ContentUnavailableView(
                    "\(Brand.name) could not open its data",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
                .frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands { EzraCommands() }

        // The item reports back whether it is shown on every pass; writing the same value again would redraw the app forever.
        MenuBarExtra(isInserted: Binding(get: { showsMenuBarItem }, set: { if $0 != showsMenuBarItem { showsMenuBarItem = $0 } })) {
            if case .success(let container) = store, let library {
                MenuBarPanel().modelContainer(container).environment(library)
            }
        } label: {
            if case .success(let container) = store, let library {
                MenuBarLabel().modelContainer(container).environment(library)
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if case .success(let container) = store, let chat {
                SettingsWindow(chat: chat, sync: sync, automations: automations).modelContainer(container)
            }
        }
    }
}

enum EzraStore {
    /// The app's open store, for the pieces that run outside the window: Shortcuts actions, notification buttons, Quick Entry.
    @MainActor static var shared: ModelContainer?

    static let schema = Schema([
        Area.self, Project.self, Heading.self, ToDo.self, ChecklistItem.self, Note.self, PlannerEvent.self,
        ChatThread.self, ChatMessage.self, Attachment.self,
    ])

    /// The store syncs through CloudKit only when the Info.plist names a container
    /// (see project.yml); otherwise it stays on this Mac.
    /// `named` opens a separate store file of that name (the load test's), never synced through iCloud.
    static func makeContainer(inMemory: Bool = false, named name: String? = nil) throws -> ModelContainer {
        if let name {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(name, schema: schema, cloudKitDatabase: .none)])
        }
        let cloudContainer = Bundle.main.object(forInfoDictionaryKey: "EzraCloudKitContainer") as? String ?? ""
        let cloudDatabase: ModelConfiguration.CloudKitDatabase =
            inMemory || cloudContainer.isEmpty ? .none : .private(cloudContainer)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudDatabase
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
