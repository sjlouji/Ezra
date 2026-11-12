import Foundation
import SwiftData
import WidgetKit

/// Keeps the desktop widgets current: after every save, writes what they show and asks them to redraw.
@MainActor
final class WidgetFeed {
    private let container: ModelContainer
    private var last: WidgetSnapshot?
    private var observer: (any NSObjectProtocol)?

    init(container: ModelContainer) {
        self.container = container
    }

    func start() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// What the widgets should show for the day containing `now`.
    static func snapshot(todos: [ToDo], now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        func item(_ todo: ToDo, day: Date?) -> WidgetSnapshot.Item {
            WidgetSnapshot.Item(
                id: todo.uuid, title: todo.title, place: todo.project?.name ?? todo.area?.name ?? "", day: day,
                isDue: (todo.daysToDeadline(now: now, calendar: calendar) ?? 1) <= 0
            )
        }
        let upcoming = todos
            .filter { SmartList.upcoming.contains($0, now: now, calendar: calendar) && ($0.startDate ?? today) > today }
            .sorted { ($0.startDate ?? .distantFuture, $0.order) < ($1.startDate ?? .distantFuture, $1.order) }
        return WidgetSnapshot(
            updated: now,
            today: todos.filter { SmartList.today.contains($0, now: now, calendar: calendar) }.prefix(12).map { item($0, day: nil) },
            upcoming: upcoming.prefix(12).map { item($0, day: $0.startDate) }
        )
    }

    private func refresh() {
        do {
            let todos = try container.mainContext.fetch(FetchDescriptor<ToDo>(sortBy: [SortDescriptor(\.order)]))
            var fresh = Self.snapshot(todos: todos)
            // Only what is shown matters: an unchanged list is not rewritten just because time has passed.
            if let last { fresh.updated = last.updated }
            guard fresh != last else { return }
            fresh.updated = .now
            try fresh.write()
            last = fresh
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            Log.store.error("The widgets could not be updated: \(String(describing: error), privacy: .public)")
        }
    }
}
