import Foundation
@preconcurrency import UserNotifications

/// The morning summary on Today: what the day holds, what is late, and what was planned earlier and not done.
struct DailyBriefing: Equatable {
    /// Open to-dos on Today, carried-over ones included.
    var planned = 0
    /// Planned for an earlier day and still open.
    var carriedOver = 0
    var dueToday = 0
    /// Titles of to-dos whose deadline has passed.
    var overdue: [String] = []
    var events = 0
    /// The first timed event still to come, as "11:00 Team meeting".
    var nextEvent: String?

    static func make(todos: [ToDo], events: [DayEvent], now: Date = .now, calendar: Calendar = .current) -> DailyBriefing {
        let today = calendar.startOfDay(for: now)
        let open = todos.filter { SmartList.today.contains($0, now: now, calendar: calendar) }
        let late = todos.filter { !$0.isCompleted && !$0.isTemplate && $0.project?.isTemplate != true && ($0.deadline.map { $0 < today } ?? false) }
        let coming = events.filter { !$0.isAllDay && $0.start > now }.min { $0.start < $1.start }
        return DailyBriefing(
            planned: open.count,
            carriedOver: open.count { $0.when == .dated && ($0.startDate.map { $0 < today } ?? false) },
            dueToday: open.count { $0.deadline.map { calendar.isDate($0, inSameDayAs: today) } ?? false },
            overdue: late.map(\.title),
            events: events.count,
            nextEvent: coming.map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" }
        )
    }

    /// The summary in plain sentences; empty parts are left out.
    var lines: [String] {
        var lines = [planned == 0 ? "Nothing is planned for today." : "\(planned) to-do\(planned == 1 ? "" : "s") today\(dueToday > 0 ? ", \(dueToday) due today" : "")."]
        if !overdue.isEmpty {
            let named = overdue.prefix(2).joined(separator: ", ") + (overdue.count > 2 ? " and \(overdue.count - 2) more" : "")
            lines.append("\(overdue.count) overdue: \(named).")
        }
        if carriedOver > 0 { lines.append("\(carriedOver) carried over from earlier days.") }
        if events > 0 { lines.append("\(events) event\(events == 1 ? "" : "s")\(nextEvent.map { ", next \($0)" } ?? "").") }
        return lines
    }

    /// What the "Plan my day" button asks the assistant.
    var prompt: String {
        "Plan my day. Show me today's to-dos, say what to do first given what is overdue or due today, and suggest what to move to another day if it is too much."
    }
}

extension ReminderScheduler {
    static let briefingID = "morning-briefing"
    static let briefingKey = "briefing.notify"

    /// A notification at 8 every morning that points at the briefing, or none. It says nothing about the day itself:
    /// it is scheduled ahead of time, so any numbers in it would be stale.
    func setMorningBriefing(_ enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.briefingID])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Good morning"
        content.body = "Your day is ready in \(Brand.name): open Today for the briefing."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.briefingID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 8, minute: 0), repeats: true)
        )
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    return Alerts.shared.message = "macOS is blocking \(Brand.name)'s notifications, so the morning briefing cannot be shown. Allow them in System Settings › Notifications."
                }
                try await center.add(request)
            } catch {
                Alerts.shared.report("schedule the morning briefing", error)
            }
        }
    }
}
