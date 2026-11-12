import Foundation
import os

/// A change to when a to-do is planned.
enum Schedule: Equatable, Sendable {
    /// No date: Anytime when the to-do has a project or area, else the Inbox.
    case unscheduled
    /// No date, and out of the Inbox even without a project.
    case anytime
    case someday
    case on(Date, evening: Bool = false)
}

enum SmartList: String, CaseIterable, Identifiable, Sendable {
    case inbox, today, upcoming, anytime, someday, logbook

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Whether `todo` belongs in this list on the day containing `now`.
    func contains(_ todo: ToDo, now: Date = .now, calendar: Calendar = .current) -> Bool {
        // A repeating template, and the to-dos inside a repeating project's template, are patterns, not work to do.
        guard !todo.isTemplate, todo.project?.isTemplate != true else { return false }
        if self == .logbook { return todo.isCompleted }
        guard !todo.isCompleted else { return false }

        let tomorrow = Self.startOfTomorrow(now: now, calendar: calendar)
        let startsByToday = todo.when == .dated && (todo.startDate.map { $0 < tomorrow } ?? true)
        let dueByToday = todo.when != .someday && (todo.deadline.map { $0 < tomorrow } ?? false)

        switch self {
        case .inbox: return todo.when == .inbox
        case .today: return startsByToday || dueByToday
        case .upcoming: return todo.when == .dated && !startsByToday
        case .anytime: return todo.when == .anytime || startsByToday
        case .someday: return todo.when == .someday
        case .logbook: return false
        }
    }

    /// How a to-do created while this list is open is scheduled.
    func newToDoSchedule(now: Date = .now, calendar: Calendar = .current) -> Schedule {
        switch self {
        case .today: .on(now)
        case .upcoming: .on(Self.startOfTomorrow(now: now, calendar: calendar))
        case .someday: .someday
        case .anytime: .anytime
        case .inbox, .logbook: .unscheduled
        }
    }

    /// Asked once for every to-do in every list, so the answer for the current day is kept: working it out means two
    /// calendar calculations, and thousands of those per redraw were a large part of what made big lists slow.
    static func startOfTomorrow(now: Date, calendar: Calendar) -> Date {
        if let kept = tomorrowKept.withLock({ $0 }), kept.calendar == calendar, kept.day.contains(now) { return kept.day.end }
        let day = DateInterval(start: calendar.startOfDay(for: now), end: Self.day(1, from: now, calendar: calendar))
        tomorrowKept.withLock { $0 = (day, calendar) }
        return day.end
    }

    private static let tomorrowKept = OSAllocatedUnfairLock<(day: DateInterval, calendar: Calendar)?>(initialState: nil)

    /// The start of the day `offset` days after the one containing `now`.
    static func day(_ offset: Int, from now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let day = calendar.date(byAdding: .day, value: offset, to: today) else {
            preconditionFailure("Calendar \(calendar.identifier) has no day \(offset) days from \(today)")
        }
        return day
    }
}

extension ToDo {
    /// Whole days from today to the deadline: 0 today, negative when overdue.
    func daysToDeadline(now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let deadline else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: deadline)).day
    }

    /// In Today's "This Evening" section.
    var isThisEvening: Bool { evening && SmartList.today.contains(self) }
}
