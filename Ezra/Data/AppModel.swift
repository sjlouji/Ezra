import SwiftData
import SwiftUI

/// What the window is showing.
enum Destination: Hashable {
    case list(SmartList)
    case project(Project)
    case area(Area)
    /// The day planner: week strip, time grid and buckets.
    case planner
    /// The AI assistant's own page.
    case assistant
    /// Lists reached through Quick Find: Tomorrow, Deadlines, Repeating, All Projects, Logged Projects.
    case special(SpecialList)
    /// Note pages: every one, or one project's.
    case notes(Project?)
}

enum SpecialList: String, CaseIterable, Identifiable {
    case tomorrow = "Tomorrow"
    case deadlines = "Deadlines"
    case repeating = "Repeating"
    case templates = "Templates"
    case allProjects = "All Projects"
    case loggedProjects = "Logged Projects"

    var id: String { rawValue }
}

/// Navigation, the to-do that is open in place, and the open When / Deadline picker.
@MainActor
@Observable
final class AppModel {
    /// Where a new to-do goes.
    struct Placement {
        var project: Project?
        var area: Area?
        var schedule: Schedule = .unscheduled
        var bucket: Bucket?
        var event: PlannerEvent?
    }

    struct OpenCard: Identifiable {
        let id = UUID()
        let todo: ToDo
        /// Just created, so its title takes the keyboard.
        var isNew = false
    }

    struct OpenPicker: Identifiable {
        enum Mode { case when, deadline }
        let id = UUID()
        let todo: ToDo
        let mode: Mode
    }

    /// The spring every open, close, move and insert shares.
    static let spring = Animation.spring(duration: 0.34, bounce: 0.1)

    var destination: Destination? = .list(.today) { didSet { visited(destination) } }
    /// The screens visited, for going back and forward, and where along it the app is.
    var trail: [Destination] = [.list(.today)]
    var trailIndex = 0
    @ObservationIgnored var isRetracing = false
    /// Whether the sidebar is tucked away; remembered between launches.
    var sidebarHidden = UserDefaults.standard.bool(forKey: AppModel.sidebarKey) {
        didSet { UserDefaults.standard.set(sidebarHidden, forKey: Self.sidebarKey) }
    }
    static let sidebarKey = "sidebar.hidden"
    static let sidebarWidth: CGFloat = 236
    /// How wide the sidebar is while its edge is being dragged; nil otherwise.
    var sidebarDrag: CGFloat?
    /// The width the sidebar is shown at right now.
    var sidebarShown: CGFloat { sidebarDrag ?? (sidebarHidden ? 0 : Self.sidebarWidth) }
    /// The to-do row being swiped with two fingers, and how far.
    var swiping: (todo: ToDo, distance: CGFloat)?
    var card: OpenCard?
    var picker: OpenPicker?
    var showsQuickFind = false
    /// The day the planner shows.
    var day = Calendar.current.startOfDay(for: .now)
    /// The event whose note page is open beside the planner.
    var openEvent: PlannerEvent?
    /// The drag in progress, if any, and the drop zone under it.
    var drag: DragSession?
    var hoverZone: UUID?
    /// What dropping here will do, shown on the dragged item.
    var dropHint: String?
    /// A line between two rows of another list, where the dragged item would land.
    var insertion: CGRect?
    /// What is on screen that a drag can interact with. Views keep these current; nothing redraws when they change.
    @ObservationIgnored var zones: [UUID: DropZone] = [:]
    @ObservationIgnored var slots: [UUID: RowSlot] = [:]
    @ObservationIgnored var runs: [UUID: [ToDo]] = [:]
    @ObservationIgnored var sortSlots: [UUID: SortSlot] = [:]
    /// The to-dos picked together, in the order they were picked.
    var selection: [ToDo] = []
    /// Text to put in the assistant's box when its screen opens.
    var assistantDraft: String?
    /// A note to show as soon as the Notes screen is up; set by a link to it.
    var noteToOpen: Note?
    /// The to-do the Move panel is open for.
    var moving: ToDo?
    /// What was typed outside any field, handed to Quick Find as its first characters.
    var quickFindSeed = ""
    /// The store; set when the window appears.
    var context: ModelContext?

    /// The bottom toolbar belongs to the to-do screens, not to notes or settings.
    var showsToolbar: Bool {
        switch destination {
        case .list, .project, .area, .planner, .special: true
        case .notes, .assistant, nil: false
        }
    }

    /// Opens a to-do in place, where it sits in its list.
    func open(_ todo: ToDo) {
        guard card?.todo != todo else { return }
        withAnimation(Self.spring) {
            discardEmptyCard()
            card = OpenCard(todo: todo)
        }
    }

    /// Adds a blank to-do to the list on screen and opens it for typing.
    func newToDo(bucket: Bucket? = nil, event: PlannerEvent? = nil, inBacklog: Bool = false) {
        var placement = placementForCurrentList()
        (placement.bucket, placement.event) = (bucket, event)
        if inBacklog { placement.schedule = .unscheduled }
        create(placement)
    }

    func create(_ placement: Placement) {
        guard let context else {
            Log.store.error("New to-do requested before the store was attached")
            Alerts.shared.message = "Could not create the to-do: the window is not ready yet."
            return
        }
        Alerts.shared.attempt("create the to-do") {
            let todo = ToDo(title: "")
            if let bucket = placement.bucket { todo.bucket = bucket }
            try withAnimation(Self.spring) {
                discardEmptyCard()
                try Workspace(context: context).insert(
                    todo, project: placement.project ?? placement.event?.project, area: placement.area,
                    schedule: placement.schedule, atTop: true
                )
                if let event = placement.event {
                    todo.event = event
                    try context.save()
                }
                card = OpenCard(todo: todo, isNew: true)
            }
        }
    }

    /// Closes the open to-do. One that was never given a title is thrown away.
    func closeCard() {
        guard card != nil || picker != nil else { return }
        withAnimation(Self.spring) {
            picker = nil
            discardEmptyCard()
            card = nil
        }
    }

    func setQuickFind(_ shown: Bool) {
        withAnimation(Self.spring) { showsQuickFind = shown }
    }

    func pick(_ mode: OpenPicker.Mode, for todo: ToDo) {
        withAnimation(.snappy(duration: 0.22)) { picker = OpenPicker(todo: todo, mode: mode) }
    }

    func closePicker() {
        withAnimation(.snappy(duration: 0.18)) { picker = nil }
    }

    /// Shows the list a to-do lives in and opens it there.
    func jump(to todo: ToDo) {
        if let project = todo.project {
            destination = .project(project)
        } else if let area = todo.area {
            destination = .area(area)
        } else {
            let lists: [SmartList] = [.logbook, .inbox, .today, .upcoming, .someday, .anytime]
            destination = .list(lists.first { $0.contains(todo) } ?? .anytime)
        }
        if !todo.isCompleted { open(todo) }
    }

    private func discardEmptyCard() {
        guard let todo = card?.todo, todo.title.trimmed.isEmpty, let context else { return }
        card = nil
        Alerts.shared.attempt("discard the empty to-do") { try Workspace(context: context).delete(todo) }
    }

    private func placementForCurrentList() -> Placement {
        switch destination {
        case .project(let project): Placement(project: project)
        case .area(let area): Placement(area: area)
        // The planner adds to the day it is showing.
        case .planner: Placement(schedule: .on(day))
        case .list(let list): Placement(schedule: list.newToDoSchedule())
        case .notes, .assistant, .special, nil: Placement()
        }
    }
}
