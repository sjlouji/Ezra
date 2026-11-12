import EventKit
import SwiftUI

/// One event as Today and Upcoming show it, whether it came from Apple Calendar or from the planner.
struct DayEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let tint: Color
}

extension PlannerEvent {
    var dayEvent: DayEvent {
        DayEvent(id: uuid.uuidString, title: title, start: start, end: end, isAllDay: isAllDay, tint: bucket.tint)
    }
}

/// Reads Apple Calendar once the user connects it. Events are shown, never stored or synced by the app,
/// so each device connects its own calendars.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()
    private static let connectedKey = "calendar.connected"
    private static let hiddenKey = "calendar.hidden"

    private let store = EKEventStore()
    private(set) var isConnected: Bool
    /// Bumped when the calendars change, so views that asked for events ask again.
    private(set) var revision = 0
    private var hidden: Set<String>

    private init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        isConnected = UserDefaults.standard.bool(forKey: Self.connectedKey) && EKEventStore.authorizationStatus(for: .event) == .fullAccess
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    /// Asks macOS for access to the calendars. A refusal is explained, since only System Settings can undo it.
    func connect() async {
        do {
            guard try await store.requestFullAccessToEvents() else {
                Alerts.shared.message = "\(Brand.name) was not given access to your calendars. Allow it in System Settings › Privacy & Security › Calendars."
                return
            }
            UserDefaults.standard.set(true, forKey: Self.connectedKey)
            isConnected = true
            revision += 1
        } catch {
            Alerts.shared.report("connect to Apple Calendar", error)
        }
    }

    func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        isConnected = false
    }

    var calendars: [EKCalendar] {
        guard isConnected else { return [] }
        return store.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func isShown(_ calendar: EKCalendar) -> Bool { !hidden.contains(calendar.calendarIdentifier) }

    func setShown(_ calendar: EKCalendar, _ shown: Bool) {
        if shown { hidden.remove(calendar.calendarIdentifier) } else { hidden.insert(calendar.calendarIdentifier) }
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenKey)
        revision += 1
    }

    /// The day's events from the calendars the user left switched on.
    func events(on day: Date) -> [DayEvent] {
        events(in: DateInterval(start: Calendar.current.startOfDay(for: day), end: SmartList.day(1, from: day)))
    }

    /// Every event that touches a stretch of time, from one query. A month view asks once, not once per day.
    func events(in interval: DateInterval) -> [DayEvent] {
        _ = revision
        let shown = calendars.filter(isShown)
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: shown)
        return store.events(matching: predicate).map { event in
            DayEvent(
                id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSinceReferenceDate)", title: event.title ?? "Untitled",
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, tint: Color(cgColor: event.calendar.cgColor)
            )
        }
    }

    /// How many events each day in `interval` has, from the calendars left switched on: one query for the whole range.
    func eventCounts(in interval: DateInterval) -> [Date: Int] {
        _ = revision
        let shown = calendars.filter(isShown)
        guard !shown.isEmpty else { return [:] }
        var counts: [Date: Int] = [:]
        for event in store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: shown)) {
            counts[Calendar.current.startOfDay(for: event.startDate), default: 0] += 1
        }
        return counts
    }

    /// The events among `all` (planner and calendar alike) that fall on `day`, all-day first.
    static func events(on day: Date, among all: [DayEvent], calendar: Calendar = .current) -> [DayEvent] {
        let start = calendar.startOfDay(for: day)
        let end = SmartList.day(1, from: day, calendar: calendar)
        return all.filter { $0.start < end && max($0.end, $0.start.addingTimeInterval(1)) > start }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Planner events and calendar events for one day, in the order they happen: all-day first.
    func merged(_ planner: [PlannerEvent], on day: Date) -> [DayEvent] {
        (planner.map(\.dayEvent) + events(on: day)).sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }
}
