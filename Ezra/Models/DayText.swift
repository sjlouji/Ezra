import Foundation

/// The date words and formats the assistant's tools exchange with the model.
enum DayText {
    static func schedule(from text: String, now: Date = .now, calendar: Calendar = .current) throws -> Schedule {
        switch text.trimmed.lowercased() {
        case "none", "unscheduled", "anytime": .unscheduled
        case "someday": .someday
        case "tonight", "evening", "this evening": .on(calendar.startOfDay(for: now), evening: true)
        default: .on(try day(from: text, now: now, calendar: calendar))
        }
    }

    static func day(from text: String, now: Date = .now, calendar: Calendar = .current) throws -> Date {
        switch text.trimmed.lowercased() {
        case "today": return calendar.startOfDay(for: now)
        case "tomorrow": return SmartList.startOfTomorrow(now: now, calendar: calendar)
        default: return try parse(text, formats: ["yyyy-MM-dd"], calendar: calendar)
        }
    }

    static func moment(from text: String, calendar: Calendar = .current) throws -> Date {
        try parse(text, formats: ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"], calendar: calendar)
    }

    /// Minutes after midnight from a 24-hour "HH:mm".
    static func minutes(from text: String) throws -> Int {
        let parts = text.trimmed.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { throw WorkspaceError.badDate(text) }
        return parts[0] * 60 + parts[1]
    }

    static func string(day: Date, calendar: Calendar = .current) -> String {
        formatter("yyyy-MM-dd", calendar: calendar).string(from: day)
    }

    static func string(moment: Date, calendar: Calendar = .current) -> String {
        formatter("yyyy-MM-dd HH:mm", calendar: calendar).string(from: moment)
    }

    private static func parse(_ text: String, formats: [String], calendar: Calendar) throws -> Date {
        for format in formats {
            if let date = formatter(format, calendar: calendar).date(from: text.trimmed) {
                return date
            }
        }
        throw WorkspaceError.badDate(text)
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
