import Foundation
import SwiftData

/// Puts the demo content in the store once, and keeps its dates current.
@MainActor
enum Seeder {
    static let seededKey = "demo.seeded"
    /// The day the demo dates are currently correct for (seconds since the reference date).
    static let anchorKey = "demo.anchorDay"
    /// Raised when the demo content changes shape; an older demo still in the store is then replaced.
    static let version = 3
    static let versionKey = "demo.version"

    /// Call at launch: seeds on the first run, then moves every demo date forward by the days since it was last current.
    static func prepare(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) throws {
        if !defaults.bool(forKey: seededKey) {
            try seed(context: context, defaults: defaults, now: now)
        } else if defaults.integer(forKey: versionKey) < version,
                  try context.fetchCount(FetchDescriptor<ToDo>(predicate: #Predicate { $0.isDemo })) > 0 {
            try reset(context: context, defaults: defaults, now: now)
        }
        defaults.set(version, forKey: versionKey)
        try shiftDemoDates(context: context, defaults: defaults, now: now)
    }

    /// Removes the demo content and seeds it again. The user's own items are left alone.
    static func reset(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) throws {
        try removeDemo(context: context)
        try seed(context: context, defaults: defaults, now: now)
    }

    static func removeDemo(context: ModelContext) throws {
        try context.fetch(FetchDescriptor<ToDo>(predicate: #Predicate { $0.isDemo })).forEach(context.delete)
        try context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.isDemo })).forEach(context.delete)
        try context.fetch(FetchDescriptor<Area>(predicate: #Predicate { $0.isDemo })).forEach(context.delete)
        try context.fetch(FetchDescriptor<PlannerEvent>(predicate: #Predicate { $0.isDemo })).forEach(context.delete)
        try context.save()
    }

    static func seed(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) throws {
        var projects: [String: Project] = [:]
        var areas: [String: Area] = [:]
        var order = 1000.0 // after anything the user already has
        func nextOrder() -> Double {
            order += 1
            return order
        }

        func makeProject(_ spec: Fixtures.ProjectSpec, in area: Area?) {
            let project = Project(name: spec.name)
            (project.details, project.order, project.isDemo) = (spec.notes, nextOrder(), true)
            context.insert(project)
            project.area = area
            for title in spec.headings {
                let heading = Heading(title: title)
                heading.order = nextOrder()
                context.insert(heading)
                heading.project = project
            }
            projects[spec.name] = project
        }

        Fixtures.looseProjects.forEach { makeProject($0, in: nil) }
        for (name, specs) in Fixtures.areas {
            let area = Area(name: name)
            (area.order, area.isDemo) = (nextOrder(), true)
            context.insert(area)
            areas[name] = area
            specs.forEach { makeProject($0, in: area) }
        }

        for spec in Fixtures.todos {
            let todo = ToDo(title: spec.title)
            (todo.notes, todo.tags, todo.order, todo.isDemo) = (spec.notes, spec.tags, nextOrder(), true)
            todo.deadline = spec.deadline.map { SmartList.day($0, from: now) }
            context.insert(todo)
            let project = spec.project.flatMap { projects[$0] }
            todo.project = project
            // Demo priorities: anything with a deadline is a fire, project work is growth, the rest is extra.
            todo.bucket = spec.deadline != nil ? .fire : project != nil ? .growth : .extra
            todo.area = project == nil ? spec.area.flatMap { areas[$0] } : nil
            todo.heading = spec.heading.flatMap { title in project?.sortedHeadings.first { $0.title == title } }
            switch spec.place {
            case .inbox: todo.when = .inbox
            case .anytime: todo.when = .anytime
            case .someday: todo.when = .someday
            case .day(let offset, let evening):
                (todo.when, todo.startDate, todo.evening) = (.dated, SmartList.day(offset, from: now), evening)
            case .done(let daysAgo):
                todo.when = .anytime
                // Mid-morning, so "today" entries are never in the future.
                todo.completedAt = min(now, SmartList.day(-daysAgo, from: now).addingTimeInterval(9 * 3600))
            }
            for item in spec.checklist {
                let entry = ChecklistItem(title: item)
                entry.createdAt = now.addingTimeInterval(nextOrder())
                context.insert(entry)
                entry.task = todo
            }
        }
        for spec in Fixtures.events {
            let day = SmartList.day(spec.day, from: now)
            let start = day.addingTimeInterval(TimeInterval(spec.minutes ?? 0) * 60)
            let end = spec.minutes == nil ? SmartList.day(spec.day + 1, from: now) : start.addingTimeInterval(3600)
            let event = PlannerEvent(title: spec.title, start: start, end: end)
            (event.isAllDay, event.bucket, event.noteBody, event.isDemo) = (spec.minutes == nil, spec.bucket, spec.note, true)
            context.insert(event)
        }
        try context.save()
        defaults.set(true, forKey: seededKey)
        defaults.set(Calendar.current.startOfDay(for: now).timeIntervalSinceReferenceDate, forKey: anchorKey)
        Log.store.info("Seeded \(Fixtures.todos.count) demo to-dos")
    }

    static func shiftDemoDates(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard defaults.object(forKey: anchorKey) != nil else { return }
        let anchor = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: anchorKey))
        guard let days = calendar.dateComponents([.day], from: anchor, to: today).day, days > 0 else { return }

        func shifted(_ date: Date?) -> Date? {
            date.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
        }
        for todo in try context.fetch(FetchDescriptor<ToDo>(predicate: #Predicate { $0.isDemo })) {
            todo.startDate = shifted(todo.startDate)
            todo.deadline = shifted(todo.deadline)
            todo.completedAt = shifted(todo.completedAt)
        }
        for event in try context.fetch(FetchDescriptor<PlannerEvent>(predicate: #Predicate { $0.isDemo })) {
            event.start = shifted(event.start) ?? event.start
            event.end = shifted(event.end) ?? event.end
        }
        try context.save()
        defaults.set(today.timeIntervalSinceReferenceDate, forKey: anchorKey)
        Log.store.info("Moved demo dates forward by \(days) days")
    }
}
