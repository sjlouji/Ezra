import Foundation
import SwiftData

/// How much a to-do or event matters today.
enum Bucket: String, CaseIterable, Identifiable, Codable, Sendable {
    case fire, growth, extra

    var id: String { rawValue }
}

/// Something with a time on the planner's calendar. Its note page can carry to-dos.
@Model
final class PlannerEvent {
    /// The same on every device; what sync knows the item by.
    var uuid: UUID = UUID()
    var title: String = ""
    var start: Date = Date.now
    var end: Date = Date.now
    var isAllDay: Bool = false
    var bucketRaw: String = Bucket.extra.rawValue
    /// The event's note page, as plain text.
    var noteBody: String = ""
    var isDemo: Bool = false
    var createdAt: Date = Date.now
    var project: Project?
    @Relationship(deleteRule: .nullify, inverse: \ToDo.event) var todos: [ToDo]? = []

    var bucket: Bucket {
        get { Bucket(rawValue: bucketRaw) ?? .extra }
        set { bucketRaw = newValue.rawValue }
    }
    var openToDos: [ToDo] { (todos ?? []).filter { !$0.isCompleted }.sorted { $0.order < $1.order } }

    init(title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }
}

/// The planner's rules: what belongs to a day, and where an event sits on the time grid.
enum Planner {
    static let firstHour = 6
    static let lastHour = 23

    /// Open to-dos for `day`: on today that includes overdue and due ones; on any other day, the ones planned for it.
    static func todos(on day: Date, from all: [ToDo], now: Date = .now, calendar: Calendar = .current) -> [ToDo] {
        if calendar.isDate(day, inSameDayAs: now) {
            return all.filter { SmartList.today.contains($0, now: now, calendar: calendar) }
        }
        return all.filter { todo in
            !todo.isCompleted && !todo.isTemplate && todo.when == .dated && (todo.startDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
        }
    }

    /// Open to-dos with no day yet.
    static func backlog(from all: [ToDo]) -> [ToDo] {
        all.filter { !$0.isCompleted && !$0.isTemplate && $0.project?.isTemplate != true && ($0.when == .inbox || $0.when == .anytime) }
    }

    static func events(on day: Date, from all: [PlannerEvent], calendar: Calendar = .current) -> [PlannerEvent] {
        let start = calendar.startOfDay(for: day)
        let end = SmartList.day(1, from: day, calendar: calendar)
        return all.filter { $0.start < end && max($0.end, $0.start.addingTimeInterval(1)) > start }.sorted { $0.start < $1.start }
    }

    /// Top offset and height of a timed event on `day`'s grid, clipped to the hours the grid shows.
    static func frame(
        start: Date, end: Date, on day: Date, hourHeight: CGFloat, calendar: Calendar = .current
    ) -> (y: CGFloat, height: CGFloat) {
        let gridStart = calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(firstHour) * 3600)
        let gridHours = Double(lastHour - firstHour)
        let from = min(max(start.timeIntervalSince(gridStart) / 3600, 0), gridHours)
        let to = min(max(end.timeIntervalSince(gridStart) / 3600, 0), gridHours)
        // A very short event still gets room for its title.
        return (CGFloat(from) * hourHeight, max(CGFloat(to - from) * hourHeight, 26))
    }
}

extension Workspace {
    func events() throws -> [PlannerEvent] {
        try context.fetch(FetchDescriptor<PlannerEvent>(sortBy: [SortDescriptor(\.start)]))
    }

    @discardableResult
    func addEvent(
        title: String, start: Date, end: Date? = nil, isAllDay: Bool = false, bucket: Bucket = .extra, project: Project? = nil
    ) throws -> PlannerEvent {
        let name = title.trimmed
        guard !name.isEmpty else { throw WorkspaceError.emptyName(kind: "event") }
        // An event without a usable end lasts an hour.
        let finish = end.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        let event = PlannerEvent(title: name, start: start, end: finish)
        event.isAllDay = isAllDay
        event.bucket = bucket
        context.insert(event)
        event.project = project
        try context.save()
        return event
    }

    /// Removes the event; to-dos on its note page are kept.
    func delete(_ event: PlannerEvent) throws {
        context.delete(event)
        try context.save()
    }
}

/// What the month and year views need to know about the calendar.
extension Planner {
    /// The 42 days a month's grid shows: six weeks from the first day of the week that holds the 1st.
    static func monthGrid(for month: Date, calendar: Calendar = .current) -> [Date] {
        let first = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let start = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        return (0..<42).map { SmartList.day($0, from: start, calendar: calendar) }
    }

    /// The seven days of the week `date` is in.
    static func week(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).map { SmartList.day($0, from: start, calendar: calendar) }
    }

    /// The first day of each month of the year `date` is in.
    static func months(ofYearContaining date: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .year, for: date)?.start ?? date
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
    }

    /// `day` moved by whole months or years, landing on the same day number where that month has one.
    static func shifted(_ day: Date, by value: Int, _ unit: Calendar.Component, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: unit, value: value, to: day) ?? day)
    }

    /// How many open to-dos (planned for the day or due on it) and events each day has. Days with nothing are absent.
    static func load(todos: [ToDo], events: [PlannerEvent], calendar: Calendar = .current) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        for todo in todos where !todo.isCompleted && !todo.isTemplate && todo.project?.isTemplate != true {
            let days = Set([todo.when == .dated ? todo.startDate : nil, todo.deadline].compactMap { $0.map(calendar.startOfDay(for:)) })
            for day in days { counts[day, default: 0] += 1 }
        }
        for event in events {
            counts[calendar.startOfDay(for: event.start), default: 0] += 1
        }
        return counts
    }
}
