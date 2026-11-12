import SwiftData
import SwiftUI

/// The window: the sidebar beside the open screen and its bottom toolbar.
struct RootView: View {
    @State private var app: AppModel
    @State private var chat: ChatModel
    /// The one fetch of the to-dos that every screen shares.
    @State private var library: Library
    @Bindable private var alerts = Alerts.shared
    @Environment(\.modelContext) private var context
    @AppStorage(Brand.Appearance.key) private var appearance = Brand.Appearance.automatic.rawValue

    init(container: ModelContainer, app: AppModel = AppModel(), chat: ChatModel? = nil, library: Library? = nil) {
        _library = State(initialValue: library ?? Library(context: container.mainContext))
        _app = State(initialValue: app)
        _chat = State(initialValue: chat ?? ChatModel(container: container))
    }

    var body: some View {
        HStack(spacing: 0) {
            // The sidebar keeps its full width and slides under the window's left edge as the space given to it shrinks.
            HomeView()
                .frame(width: AppModel.sidebarWidth)
                .opacity(0.35 + 0.65 * app.sidebarShown / AppModel.sidebarWidth)
                .frame(width: app.sidebarShown, alignment: .trailing)
                .clipped()
                .allowsHitTesting(!app.sidebarHidden && app.sidebarDrag == nil)
                .overlay(alignment: .trailing) { SidebarEdge().offset(x: 5) }
                .zIndex(1)
            VStack(spacing: 0) {
                ZStack {
                    // While a to-do is open the page recedes to grey and the to-do stands out as a white card.
                    (app.card == nil ? Brand.Palette.page : Brand.Palette.pageOpen)
                        .ignoresSafeArea()
                        .animation(AppModel.spring, value: app.card?.id)
                    screen
                        .id(app.destination)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.16), value: app.destination)
                    if let picker = app.picker {
                        Color.black.opacity(0.08)
                            .onTapGesture { app.closePicker() }
                        WhenPicker(picker: picker)
                            .id(picker.id)
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                }
                if app.showsToolbar {
                    BottomBar()
                }
            }
            // With the sidebar away, the window's close, minimise and zoom buttons sit over the page; keep the page clear of them.
            .padding(.top, app.sidebarHidden && app.sidebarDrag == nil ? 26 : 0)
            .background(Brand.Palette.page)
        }
        .overlay(alignment: .top) {
            if LoadTest.active > 0 {
                Text("Load test: \(LoadTest.active.formatted()) made-up to-dos. Not your data; nothing here syncs.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 10)
                    .background(Brand.Palette.deadline, in: .capsule)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            Button(app.sidebarHidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
                app.setSidebar(hidden: !app.sidebarHidden)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.hand)
            .font(.system(size: 13))
            .foregroundStyle(Brand.Palette.secondary)
            .keyboardShortcut("/")
            .help(app.sidebarHidden ? "Show the sidebar (⌘/)" : "Hide the sidebar (⌘/)")
            // Just right of the window's own three buttons.
            .padding(.leading, 82)
            .padding(.top, 7)
        }
        // Dragging something to the window's left edge brings a hidden sidebar back, so there is somewhere to drop it.
        .onChange(of: (app.drag?.location.x ?? 100) < 14) { _, atEdge in
            if atEdge, app.sidebarHidden { app.setSidebar(hidden: false) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay { DragLayer() }
        .preferredColorScheme(Brand.Appearance(rawValue: appearance)?.scheme)
        .tint(Brand.Palette.accent)
        // Sidebar (236) + the narrowest usable screen.
        .frame(minWidth: 640, minHeight: 480)
        // ⌘J goes to the assistant from anywhere.
        .background {
            Button("Back") { app.goBack() }.keyboardShortcut("[").disabled(!app.canGoBack).hidden()
            Button("Forward") { app.goForward() }.keyboardShortcut("]").disabled(!app.canGoForward).hidden()
            Button(Brand.assistant) { app.destination = .assistant }
                .keyboardShortcut("j")
                .hidden()
        }
        .overlay {
            if app.showsQuickFind {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.1)
                        .ignoresSafeArea()
                        .onTapGesture { app.setQuickFind(false) }
                    QuickFindView()
                        .clipShape(.rect(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.25), radius: 28, y: 10)
                        .padding(.top, 64)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .overlay {
            if let todo = app.moving {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.1)
                        .ignoresSafeArea()
                        .onTapGesture { app.moving = nil }
                    MoveView(todo: todo)
                        .clipShape(.rect(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.25), radius: 28, y: 10)
                        .padding(.top, 64)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .background { ToDoShortcuts() }
        .onAppear {
            app.context = context
            TypeToSearch.install(for: app)
            SwipeMonitor.install(for: app)
        }
        // Links such as ezra:///add?title=… from Claude, other agents, scripts and Shortcuts.
        .onOpenURL { url in
            // A click on a desktop widget.
            if url.path == "/show" { return app.destination = .list(.today) }
            // ezra:///chat?q=…&model=claude opens the assistant with the question in its box. It is never sent unasked:
            // a link from anywhere could otherwise make the assistant change things.
            if url.path == "/chat" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let engine = items.first(where: { $0.name == "model" })?.value.flatMap(AssistantEngine.init(link:)) { chat.engine = engine }
                app.assistantDraft = items.first { $0.name == "q" }?.value
                return app.destination = .assistant
            }
            guard let command = AddCommand(url: url) else {
                return Alerts.shared.message = "\(Brand.name) does not understand the link \(url.absoluteString)."
            }
            Alerts.shared.attempt("add the to-do from the link") { try command.run(in: Workspace(context: context)) }
        }
        .task { await DemoScript.run(app: app, context: context) }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { alerts.message != nil }, set: { if !$0 { alerts.message = nil } })
        ) {
            if let link = alerts.settingsLink {
                Button(link.label) {
                    NSWorkspace.shared.open(link.url)
                    (alerts.message, alerts.settingsLink) = (nil, nil)
                }
            }
            Button("OK") { (alerts.message, alerts.settingsLink) = (nil, nil) }
        } message: {
            Text(alerts.message ?? "")
        }
        // Last, so every overlay above (Quick Find, the Move panel, the shortcuts) can reach the navigation state.
        .environment(app)
        .environment(library)
    }

    @ViewBuilder
    private var screen: some View {
        switch app.destination {
        case .list(.inbox): InboxView()
        case .list(.today): TodayView()
        case .list(.upcoming): UpcomingView()
        case .list(.anytime): GroupedListView(list: .anytime)
        case .list(.someday): GroupedListView(list: .someday)
        case .list(.logbook): LogbookView()
        case .planner: PlannerView()
        case .project(let project): ProjectView(project: project).id(project.persistentModelID)
        case .area(let area): AreaView(area: area).id(area.persistentModelID)
        case .notes(let project): NotesBrowser(project: project)
        case .assistant: ChatView(model: chat)
        case .special(let kind): SpecialListView(kind: kind)
        case nil: ContentUnavailableView("Nothing selected", systemImage: "sidebar.left")
        }
    }
}

/// Keyboard commands for the open to-do: When (⌘S), Deadline (⇧⌘D), Move (⇧⌘M), Today (⌘T), This Evening (⌘E),
/// Anytime (⌘R), Someday (⌘O) and Complete (⌘K).
private struct ToDoShortcuts: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            command("When", "s") { app.pick(.when, for: $0) }
            command("Deadline", "d", [.command, .shift]) { app.pick(.deadline, for: $0) }
            command("Move", "m", [.command, .shift]) { app.moving = $0 }
            command("Today", "t") { plan($0, .on(.now)) }
            command("This Evening", "e") { plan($0, .on(.now, evening: true)) }
            command("Anytime", "r") { plan($0, .anytime) }
            command("Someday", "o") { plan($0, .someday) }
            command("Complete", "k") { todo in
                Alerts.shared.attempt("complete the to-do") { try Workspace(context: context).setCompleted(todo, true) }
                app.closeCard()
            }
        }
        .hidden()
    }

    private func command(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command, action: @escaping (ToDo) -> Void) -> some View {
        Button(title) { if let todo = app.card?.todo { action(todo) } }
            .keyboardShortcut(key, modifiers: modifiers)
    }

    private func plan(_ todo: ToDo, _ schedule: Schedule) {
        Alerts.shared.attempt("reschedule the to-do") {
            try withAnimation(AppModel.spring) { try Workspace(context: context).schedule(todo, schedule) }
        }
    }
}

/// Typing with nothing selected starts Quick Find with what was typed.
@MainActor
enum TypeToSearch {
    private static var monitor: Any?

    static func install(for app: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typed = event.charactersIgnoringModifiers ?? ""
            let isPlainKey = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard isPlainKey, typed.count == 1, typed.first?.isLetter == true || typed.first?.isNumber == true else { return event }
            // Key events are delivered on the main thread.
            let opened = MainActor.assumeIsolated {
                let isInText = NSApp.keyWindow?.firstResponder is NSText
                guard !isInText, app.showsToolbar, app.card == nil, app.picker == nil, app.moving == nil, !app.showsQuickFind else { return false }
                app.quickFindSeed = typed
                app.setQuickFind(true)
                return true
            }
            return opened ? nil : event
        }
    }
}

/// The sidebar's right edge, for the mouse: drag it left to close the sidebar or right to open it; double-click to toggle.
/// When the sidebar is hidden it sits at the window's left edge.
private struct SidebarEdge: View {
    @Environment(AppModel.self) private var app
    @State private var startWidth: CGFloat?
    @State private var hovered = false

    var body: some View {
        Rectangle()
            .fill(Brand.Palette.accent.opacity(hovered || app.sidebarDrag != nil ? 0.35 : 0))
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            // A wider strip than the line that shows, so it is easy to catch.
            .padding(.horizontal, 5)
            .contentShape(.rect)
            .onHover { hovered = $0 }
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startWidth ?? app.sidebarShown
                        startWidth = start
                        app.dragSidebar(to: start + drag.translation.width)
                    }
                    .onEnded { drag in
                        app.endSidebarDrag(predicted: (startWidth ?? 0) + drag.predictedEndTranslation.width)
                        startWidth = nil
                    }
            )
            .onTapGesture(count: 2) { app.setSidebar(hidden: !app.sidebarHidden) }
            .help(app.sidebarHidden ? "Drag right, or double-click, to show the sidebar" : "Drag left, or double-click, to hide the sidebar")
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}
