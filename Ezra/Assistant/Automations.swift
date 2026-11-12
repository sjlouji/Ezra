import Foundation
import SwiftData

/// A prompt the assistant runs by itself on a schedule, while the app is open. Each run is saved as its own chat.
struct Automation: Codable, Identifiable, Equatable {
    enum Every: String, Codable, CaseIterable, Identifiable {
        case hour, day, week, month
        var id: String { rawValue }
        var title: String { "Every \(rawValue)" }
    }

    var id = UUID()
    var title = ""
    var prompt = ""
    var every = Every.day
    /// The time of day it runs (the minute alone, for hourly).
    var hour = 8
    var minute = 0
    /// For weekly: 1 is Sunday.
    var weekday = 2
    /// For monthly: the day of the month, 1 to 28 so every month has it.
    var day = 1
    var enabled = true
    var createdAt = Date.now
    var lastRun: Date?

    /// The first scheduled moment after `date`.
    func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        var wanted = DateComponents(minute: minute, second: 0)
        switch every {
        case .hour: break
        case .day: wanted.hour = hour
        case .week: (wanted.hour, wanted.weekday) = (hour, weekday)
        case .month: (wanted.hour, wanted.day) = (hour, day)
        }
        return calendar.nextDate(after: date, matching: wanted, matchingPolicy: .nextTime) ?? .distantFuture
    }

    /// Whether a scheduled moment has passed since it last ran (or since it was made). Several missed runs count as one.
    func isDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        enabled && !prompt.trimmed.isEmpty && nextRun(after: lastRun ?? createdAt, calendar: calendar) <= now
    }

    var schedule: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch every {
        case .hour: return "Every hour at :\(String(format: "%02d", minute))"
        case .day: return "Every day at \(time)"
        case .week: return "Every \(Calendar.current.weekdaySymbols[max(min(weekday, 7), 1) - 1]) at \(time)"
        case .month: return "On day \(day) of every month at \(time)"
        }
    }
}

/// The automations of this Mac. They are not synced: a schedule that ran on every device would run several times over.
@MainActor
@Observable
final class AutomationStore {
    static let shared = AutomationStore()
    private static let key = "automations"
    private let defaults: UserDefaults
    private(set) var problem: String?

    var items: [Automation] {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(items), forKey: Self.key)
            } catch {
                Alerts.shared.report("save the automations", error)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            items = try defaults.data(forKey: Self.key).map { try JSONDecoder().decode([Automation].self, from: $0) } ?? []
        } catch {
            Log.assistant.error("The saved automations could not be read: \(String(describing: error), privacy: .public)")
            items = []
            problem = "The saved automations could not be read, so none are loaded. \(error.localizedDescription)"
        }
    }

    func markRun(_ id: UUID, at date: Date = .now) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].lastRun = date }
    }
}

/// Runs what is due, once a minute, each in a chat of its own.
@MainActor
final class AutomationRunner {
    private let store: AutomationStore
    private let makeChat: () -> ChatModel
    private var timer: Timer?
    private var running = false

    init(store: AutomationStore = .shared, makeChat: @escaping () -> ChatModel) {
        (self.store, self.makeChat) = (store, makeChat)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runDue() }
        }
    }

    /// Runs every automation that is due; one at a time, so two never write into each other's chat.
    func runDue(now: Date = .now) async {
        guard !running else { return }
        running = true
        defer { running = false }
        for automation in store.items where automation.isDue(now: now) { await run(automation, at: now) }
    }

    func run(_ automation: Automation, at date: Date = .now) async {
        // Marked first: a run that fails is reported in its chat, not retried every minute.
        store.markRun(automation.id, at: date)
        let chat = makeChat()
        chat.params.followUps = false
        await chat.send(automation.prompt)
        if let thread = chat.thread {
            chat.rename(thread, to: "⏱ \(automation.title.isEmpty ? "Automation" : automation.title)")
            chat.move(thread, toFolder: "Automations")
        }
        let reply = chat.messages.last
        chat.notify(
            reply?.role == .failure ? "Automation failed: \(automation.title)" : "Automation ran: \(automation.title)",
            String((reply?.text ?? "").prefix(140))
        )
    }
}
