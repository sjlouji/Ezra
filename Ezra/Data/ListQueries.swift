import Foundation
import SwiftData

/// The rules of the lists, written as conditions the database can apply itself, so a list can be counted or fetched a
/// page at a time without loading every to-do. Each must agree exactly with `SmartList.contains`; `ListQueryTests` holds them to it.
/// The conditions are built from small parts because the compiler cannot type-check them written as one expression.
enum ListQuery {
    /// Not a repeating template, and not inside a project that is a template or blueprint.
    private static func real() -> Predicate<ToDo> {
        let loose = #Predicate<ToDo> { $0.project == nil }
        let housed = #Predicate<ToDo> { $0.project?.repeatRuleData == nil && $0.project?.isBlueprint == false }
        return #Predicate<ToDo> { $0.repeatRuleData == nil && (loose.evaluate($0) || housed.evaluate($0)) }
    }

    private static func open() -> Predicate<ToDo> {
        let real = real()
        return #Predicate<ToDo> { $0.completedAt == nil && real.evaluate($0) }
    }

    /// To-dos waiting in the Inbox.
    static func inbox() -> Predicate<ToDo> {
        let (open, inbox) = (open(), When.inbox.rawValue)
        return #Predicate<ToDo> { $0.whenRaw == inbox && open.evaluate($0) }
    }

    /// To-dos on Today: planned for today or earlier, or due by today.
    static func today(now: Date = .now, calendar: Calendar = .current) -> Predicate<ToDo> {
        let tomorrow = SmartList.startOfTomorrow(now: now, calendar: calendar)
        let (dated, someday) = (When.dated.rawValue, When.someday.rawValue)
        let (never, always) = (Date.distantFuture, Date.distantPast)
        // A dated to-do with no date counts as started; a to-do with no deadline is never due.
        let started = #Predicate<ToDo> { $0.whenRaw == dated && ($0.startDate ?? always) < tomorrow }
        let due = #Predicate<ToDo> { $0.whenRaw != someday && ($0.deadline ?? never) < tomorrow }
        let open = open()
        return #Predicate<ToDo> { open.evaluate($0) && (started.evaluate($0) || due.evaluate($0)) }
    }

    /// Open to-dos whose deadline is today or has passed (the red pill beside Today).
    static func due(now: Date = .now, calendar: Calendar = .current) -> Predicate<ToDo> {
        let tomorrow = SmartList.startOfTomorrow(now: now, calendar: calendar)
        let never = Date.distantFuture
        let late = #Predicate<ToDo> { ($0.deadline ?? never) < tomorrow }
        return #Predicate<ToDo> { $0.completedAt == nil && $0.repeatRuleData == nil && late.evaluate($0) }
    }

    /// Completed to-dos: the Logbook.
    static func logbook() -> Predicate<ToDo> {
        let real = real()
        return #Predicate<ToDo> { $0.completedAt != nil && real.evaluate($0) }
    }
}
