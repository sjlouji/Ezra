import Foundation
import SwiftData

/// How a to-do or project repeats. The item that carries a rule is the template; the copies made from it are what gets done.
struct RepeatRule: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        /// On fixed days, whether or not the last copy was done.
        case schedule
        /// A set time after the last copy is completed.
        case afterCompletion
    }

    enum Unit: String, Codable, CaseIterable {
        case day, week, month, year

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    var mode = Mode.schedule
    var every = 1
    var unit = Unit.week
    /// The day the next copy is for.
    var next: Date?
    var isPaused = false
    /// For a weekly schedule: the days of the week it falls on (1 is Sunday). Nil or empty means the day it started on.
    var weekdays: [Int]?
    /// Each copy is due this many days after its day (0 is the same day); nil for no deadline.
    var deadlineAfter: Int?

    /// The chosen weekdays, when they apply.
    private var days: Set<Int> { mode == .schedule && unit == .week ? Set(weekdays ?? []) : [] }

    var summary: String {
        let span = every == 1 ? unit.rawValue : "\(every) \(unit.rawValue)s"
        var text = mode == .schedule ? "Every \(span)" : "\(every == 1 ? "A" : "\(every)") \(every == 1 ? unit.rawValue : "\(unit.rawValue)s") after completion"
        if !days.isEmpty {
            text += " on " + days.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        }
        if let deadlineAfter { text += deadlineAfter == 0 ? ", due that day" : ", due \(deadlineAfter) day\(deadlineAfter == 1 ? "" : "s") later" }
        return isPaused ? "\(text) (paused)" : text
    }

    /// The occurrence after `date`.
    func advanced(_ date: Date, calendar: Calendar = .current) -> Date {
        guard !days.isEmpty, let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start else {
            return calendar.date(byAdding: unit.component, value: max(every, 1), to: date) ?? date
        }
        // The next chosen weekday: later this week, or in the week `every` weeks on.
        for offset in 1...(7 * max(every, 1) + 7) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  days.contains(calendar.component(.weekday, from: day)),
                  let itsWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start,
                  let weeks = calendar.dateComponents([.weekOfYear], from: week, to: itsWeek).weekOfYear
            else { continue }
            if weeks % max(every, 1) == 0 { return day }
        }
        return date
    }

    /// `date` itself when it falls on a chosen weekday, else the first chosen weekday after it.
    func aligned(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        guard !days.isEmpty, !days.contains(calendar.component(.weekday, from: day)) else { return day }
        return (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
            .first { days.contains(calendar.component(.weekday, from: $0)) } ?? day
    }
}

extension ToDo {
    var repeatRule: RepeatRule? {
        get { RepeatRule.decoded(from: repeatRuleData) }
        set { repeatRuleData = newValue.flatMap { try? JSONEncoder().encode($0) } } // a rule of plain values always encodes
    }
    /// A repeating to-do's pattern. It is never done itself and shows only in the Repeating list.
    var isTemplate: Bool { repeatRuleData != nil }
}

extension Project {
    var repeatRule: RepeatRule? {
        get { RepeatRule.decoded(from: repeatRuleData) }
        set { repeatRuleData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    /// A pattern, not work to do: a repeating project's template, or a project saved to be stamped out again.
    var isTemplate: Bool { repeatRuleData != nil || isBlueprint }
}

extension RepeatRule {
    fileprivate static func decoded(from data: Data?) -> RepeatRule? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(RepeatRule.self, from: data)
        } catch {
            Log.store.error("A repeat rule could not be read: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension Workspace {
    /// Makes a to-do repeat (it becomes the template, and its first copy appears), changes its rule, or with nil stops it.
    func setRepeat(_ todo: ToDo, _ rule: RepeatRule?) throws {
        var rule = rule
        if rule != nil, rule?.next == nil { rule?.next = todo.startDate ?? Calendar.current.startOfDay(for: .now) }
        // Choosing weekdays moves the next occurrence onto one of them.
        if let chosen = rule, let next = chosen.next { rule?.next = chosen.aligned(next) }
        todo.repeatRule = rule
        try context.save()
        try generateRepeats()
    }

    func setRepeat(_ project: Project, _ rule: RepeatRule?) throws {
        var rule = rule
        if rule != nil, rule?.next == nil { rule?.next = Calendar.current.startOfDay(for: .now) }
        project.repeatRule = rule
        try context.save()
        try generateRepeats()
    }

    /// Creates the copies that are due. Safe to call at any time: a copy that exists is never made twice.
    func generateRepeats(now: Date = .now, calendar: Calendar = .current) throws {
        let today = calendar.startOfDay(for: now)
        let todos = try allToDos()
        for template in todos where template.isTemplate {
            guard var rule = template.repeatRule, !rule.isPaused else { continue }
            var copies = todos.filter { $0.templateUUID == template.uuid }
            func ensureCopy(on day: Date) {
                guard !copies.contains(where: { $0.startDate == day }) else { return }
                copies.append(copy(of: template, on: day, calendar: calendar))
            }
            switch rule.mode {
            case .schedule:
                var next = calendar.startOfDay(for: rule.next ?? today)
                // Occurrences missed while the app was closed collapse into the latest one.
                while rule.advanced(next, calendar: calendar) <= today { next = rule.advanced(next, calendar: calendar) }
                if next <= today {
                    ensureCopy(on: next)
                    next = rule.advanced(next, calendar: calendar)
                }
                ensureCopy(on: next) // the coming one, so it shows in Upcoming
                rule.next = next
            case .afterCompletion:
                guard !copies.contains(where: { !$0.isCompleted }) else { break }
                let lastDone = copies.compactMap(\.completedAt).max()
                ensureCopy(on: lastDone.map { rule.advanced(calendar.startOfDay(for: $0), calendar: calendar) } ?? calendar.startOfDay(for: rule.next ?? today))
            }
            template.repeatRule = rule
        }

        let projects = try projects()
        for template in projects where template.isTemplate {
            guard var rule = template.repeatRule, !rule.isPaused else { continue }
            let copies = projects.filter { $0.templateUUID == template.uuid }
            var next = rule.next.map(calendar.startOfDay(for:))
            if rule.mode == .afterCompletion {
                guard !copies.contains(where: { !$0.isCompleted }) else { continue }
                if let lastDone = copies.compactMap(\.completedAt).max() {
                    next = rule.advanced(calendar.startOfDay(for: lastDone), calendar: calendar)
                } else if next == nil {
                    next = today
                }
            }
            guard var due = next, due <= today else {
                rule.next = next
                template.repeatRule = rule
                continue
            }
            while rule.advanced(due, calendar: calendar) <= today { due = rule.advanced(due, calendar: calendar) }
            copy(of: template)
            rule.next = rule.mode == .schedule ? rule.advanced(due, calendar: calendar) : nil
            template.repeatRule = rule
        }
        try context.save()
    }

    @discardableResult
    private func copy(of template: ToDo, on day: Date, calendar: Calendar) -> ToDo {
        let copy = ToDo(title: template.title)
        (copy.notes, copy.tags, copy.bucketRaw, copy.order) = (template.notes, template.tags, template.bucketRaw, template.order)
        (copy.when, copy.startDate, copy.evening, copy.templateUUID) = (.dated, day, template.evening, template.uuid)
        copy.deadline = template.repeatRule?.deadlineAfter.flatMap { calendar.date(byAdding: .day, value: $0, to: day) }
        if let reminder = template.reminderAt {
            let time = calendar.dateComponents([.hour, .minute], from: reminder)
            copy.reminderAt = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day)
        }
        context.insert(copy)
        (copy.project, copy.area, copy.heading) = (template.project, template.area, template.heading)
        for item in template.sortedChecklist {
            let entry = ChecklistItem(title: item.title)
            entry.createdAt = item.createdAt
            context.insert(entry)
            entry.task = copy
        }
        reminders?.sync(copy)
        return copy
    }

    /// Saves a copy of a project as a template: its headings and to-dos, without dates or completion.
    @discardableResult
    func saveAsTemplate(_ project: Project) throws -> Project {
        let blueprint = copy(of: project)
        (blueprint.isBlueprint, blueprint.templateUUID, blueprint.name) = (true, nil, project.name)
        try context.save()
        return blueprint
    }

    /// A new project made from a template, placed after the user's other projects.
    @discardableResult
    func stampOut(_ blueprint: Project, name: String? = nil) throws -> Project {
        let project = copy(of: blueprint)
        project.name = try name.map { try Self.cleaned($0, kind: "project") } ?? blueprint.name
        project.templateUUID = nil // it is its own project from here on
        project.order = (try projects().map(\.order).max() ?? 0) + 1
        try context.save()
        return project
    }

    /// A fresh project with the template's headings and to-dos, none of them done.
    @discardableResult
    private func copy(of template: Project) -> Project {
        let copy = Project(name: template.name)
        (copy.details, copy.order, copy.templateUUID) = (template.details, template.order, template.uuid)
        context.insert(copy)
        copy.area = template.area
        var headings: [UUID: Heading] = [:]
        for heading in template.sortedHeadings {
            let twin = Heading(title: heading.title)
            twin.order = heading.order
            context.insert(twin)
            twin.project = copy
            headings[heading.uuid] = twin
        }
        for todo in (template.tasks ?? []).sorted(by: { $0.order < $1.order }) {
            let twin = ToDo(title: todo.title)
            (twin.notes, twin.tags, twin.bucketRaw, twin.order, twin.when) = (todo.notes, todo.tags, todo.bucketRaw, todo.order, .anytime)
            context.insert(twin)
            twin.project = copy
            twin.heading = todo.heading.flatMap { headings[$0.uuid] }
            for item in todo.sortedChecklist {
                let entry = ChecklistItem(title: item.title)
                entry.createdAt = item.createdAt
                context.insert(entry)
                entry.task = twin
            }
        }
        return copy
    }
}
