import Foundation
import SwiftData

/// The to-dos, fetched once and shared by every screen in the window, the sidebar and the menu bar.
///
/// Each of those used to ask the store for every to-do itself, and the store answered each of them again after every
/// change, a typed letter included. With thousands of to-dos that made the whole app wait. Here the open to-dos are
/// fetched once, kept, and fetched again only when something has been saved; a change to one to-do (its title, its
/// date) reaches the views through the to-do itself, without any fetching.
@MainActor
@Observable
final class Library {
    /// Every to-do that is not completed, in the user's order.
    private(set) var open: [ToDo] = []
    /// The completed ones. Kept current only once a screen has asked for them (the Logbook).
    private(set) var done: [ToDo] = []
    /// What the sidebar shows beside Inbox and Today, and how many are due or overdue.
    private(set) var inbox = 0
    private(set) var today = 0
    private(set) var due = 0
    /// Goes up each time the store has been saved. A screen that fetches its own page reads this, so it fetches again then.
    private(set) var revision = 0

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var keepsDone = false
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(context: ModelContext) {
        self.context = context
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Asks for the completed to-dos to be kept current from now on.
    func wantDone() {
        guard !keepsDone else { return }
        keepsDone = true
        refresh()
    }

    /// One page of the Logbook: the newest `limit` completed to-dos, newest first.
    func completed(limit: Int) throws -> [ToDo] {
        var page = FetchDescriptor(predicate: ListQuery.logbook(), sortBy: [SortDescriptor(\ToDo.completedAt, order: .reverse)])
        page.fetchLimit = limit
        return try context.fetch(page)
    }

    /// How many completed to-dos there are in all.
    func completedCount() throws -> Int {
        try context.fetchCount(FetchDescriptor(predicate: ListQuery.logbook()))
    }

    /// Fetches again. Called after every save; call it directly after changing data without saving.
    func refresh(now: Date = .now) {
        do {
            open = try context.fetch(FetchDescriptor<ToDo>(predicate: #Predicate { $0.completedAt == nil }, sortBy: [SortDescriptor(\.order)]))
            if keepsDone {
                done = try context.fetch(FetchDescriptor<ToDo>(predicate: #Predicate { $0.completedAt != nil }, sortBy: [SortDescriptor(\.order)]))
            }
            // Counted by the database, not by walking the to-dos.
            inbox = try context.fetchCount(FetchDescriptor(predicate: ListQuery.inbox()))
            today = try context.fetchCount(FetchDescriptor(predicate: ListQuery.today(now: now)))
            due = try context.fetchCount(FetchDescriptor(predicate: ListQuery.due(now: now)))
            revision += 1
        } catch {
            // The lists keep what they last showed, and the failure is put in front of the user rather than hidden.
            Alerts.shared.report("read your to-dos", error)
        }
    }
}
