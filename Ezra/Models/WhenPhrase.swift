import Foundation

/// One thing a typed phrase could mean: a day (or Someday), optionally with a reminder time.
struct WhenSuggestion: Equatable {
    let label: String
    /// nil means Someday.
    let date: Date?
    var evening = false
    /// A reminder on that day, in minutes after midnight.
    var reminderMinutes: Int?

    var reminderDate: Date? {
        guard let date, let reminderMinutes else { return nil }
        return Calendar.current.date(byAdding: .minute, value: reminderMinutes, to: date)
    }
}

/// Reads typed dates: "tom", "fri", "next week", "17d", "in 3 weeks", "jul 9", "10-3", "3rd wed jul", "last fri jul",
/// "2026-12-01"; and a trailing time for a reminder: "tom 2p", "fri at 9:30am", "10-3 9".
enum WhenPhrase {
    static func suggestions(
        for text: String, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> [WhenSuggestion] {
        var words = text.trimmed.lowercased().split { $0 == " " || $0 == "," }.map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = days(words, now: now, calendar: calendar, locale: locale)

        // A trailing time is a reminder. A bare hour ("9") counts only where the rest already reads as a date, or after "at".
        var minutes: Int?
        if let last = words.last {
            let followsAt = words.count >= 2 && words[words.count - 2] == "at"
            let rest = Array(words.dropLast(followsAt ? 2 : 1))
            let restIsADate = !rest.isEmpty && !days(rest, now: now, calendar: calendar, locale: locale).isEmpty
            if let parsed = time(last, allowsBareHour: followsAt || (whole.isEmpty && restIsADate)), !(whole.isEmpty == false && !followsAt && Int(last) != nil) {
                (minutes, words) = (parsed, rest)
            }
        }
        guard let minutes else { return Array(whole.prefix(4)) }
        let base = words.isEmpty
            ? [WhenSuggestion(label: "Today", date: calendar.startOfDay(for: now))]
            : days(words, now: now, calendar: calendar, locale: locale)
        let clock = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(minutes * 60)).formatted(.dateTime.hour().minute())
        return base.filter { $0.date != nil }.prefix(4).map {
            WhenSuggestion(label: "\($0.label), \(clock)", date: $0.date, evening: $0.evening, reminderMinutes: minutes)
        }
    }

    /// Minutes after midnight for "2p", "2pm", "9:30am", "14:00", or a bare hour where allowed.
    static func time(_ word: String, allowsBareHour: Bool) -> Int? {
        guard let match = word.wholeMatch(of: #/(\d{1,2})(?::(\d{2}))?(a|am|p|pm)?/#) else { return nil }
        guard var hour = Int(match.1), let minute = match.2.map({ Int($0) ?? 60 }) ?? 0 as Int? else { return nil }
        let suffix = match.3.map(String.init)
        guard suffix != nil || match.2 != nil || allowsBareHour else { return nil }
        if let suffix {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (suffix.hasPrefix("p") ? 12 : 0)
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private static func days(_ words: [String], now: Date, calendar: Calendar, locale: Locale) -> [WhenSuggestion] {
        let phrase = words.joined(separator: " ")
        let today = calendar.startOfDay(for: now)
        var found: [WhenSuggestion] = []
        func add(_ label: String, _ date: Date?, evening: Bool = false) {
            guard !found.contains(where: { $0.date == date && $0.evening == evening }) else { return }
            found.append(WhenSuggestion(label: label, date: date, evening: evening))
        }
        func named(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

        if "today".hasPrefix(phrase) { add("Today", today) }
        if "tonight".hasPrefix(phrase) || "this evening".hasPrefix(phrase) || "evening".hasPrefix(phrase) { add("This Evening", today, evening: true) }
        if "tomorrow".hasPrefix(phrase) { add("Tomorrow", SmartList.day(1, from: now, calendar: calendar)) }
        if phrase.count >= 2, words.count == 1 {
            for offset in 1...7 {
                let day = SmartList.day(offset, from: now, calendar: calendar)
                let name = calendar.weekdaySymbols[calendar.component(.weekday, from: day) - 1]
                if name.lowercased().hasPrefix(phrase) { add(name, day) }
            }
        }
        if phrase == "next week", let start = calendar.dateInterval(of: .weekOfYear, for: SmartList.day(7, from: now, calendar: calendar))?.start {
            add("Next Week", start)
        }
        if phrase == "next month", let start = calendar.date(byAdding: .month, value: 1, to: today).flatMap({ calendar.dateInterval(of: .month, for: $0)?.start }) {
            add("Next Month", start)
        }

        // "17d", "2 w", "in 3", "in 3 weeks"
        if let match = phrase.wholeMatch(of: #/(in )?(\d{1,3}) ?([a-z]*)/#), let amount = Int(match.2), amount > 0, match.1 != nil || !match.3.isEmpty {
            let units: [(name: String, aliases: [String], component: Calendar.Component)] = [
                ("day", ["d"], .day), ("week", ["w", "wk", "wks"], .weekOfYear), ("month", ["mo"], .month), ("year", ["y", "yr", "yrs"], .year),
            ]
            let typed = String(match.3)
            for unit in units where typed.isEmpty ? unit.name != "year" : (unit.aliases.contains(typed) || unit.name.hasPrefix(typed) || "\(unit.name)s" == typed) {
                if let date = calendar.date(byAdding: unit.component, value: amount, to: today) {
                    add("in \(amount) \(unit.name)\(amount == 1 ? "" : "s")", date)
                }
            }
        }

        let months = calendar.monthSymbols.map { $0.lowercased() }
        func month(_ word: String) -> Int? {
            guard word.count >= 3 else { return nil }
            return months.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 }
        }
        /// The given day; with no year, its next occurrence from today on.
        func date(month: Int, day: Int, year: Int?) -> Date? {
            for candidate in [year ?? calendar.component(.year, from: today), calendar.component(.year, from: today) + 1] {
                var parts = DateComponents(year: candidate, month: month, day: day)
                parts.calendar = calendar
                guard parts.isValidDate, let date = calendar.date(from: parts) else { continue }
                if year != nil || date >= today { return date }
            }
            return nil
        }
        var tokens = words.flatMap { word -> [String] in
            // "jul9" reads as "jul 9"
            guard let split = word.wholeMatch(of: #/([a-z]+)(\d{1,2})/#) else { return [word] }
            return [String(split.1), String(split.2)]
        }
        let year = tokens.last.flatMap { $0.count == 4 ? Int($0) : nil }
        if year != nil { tokens.removeLast() }

        // "jul 9", "9 jul"
        if tokens.count == 2 {
            for (name, number) in [(tokens[0], tokens[1]), (tokens[1], tokens[0])] {
                if let month = month(name), let day = Int(number), let date = date(month: month, day: day, year: year) { add(named(date), date) }
            }
        }
        // "10-3", "10/3", "10.3.2027", in the region's order
        if tokens.count == 1, let match = tokens[0].wholeMatch(of: #/(\d{1,2})[-/.](\d{1,2})(?:[-/.](\d{2,4}))?/#), let first = Int(match.1), let second = Int(match.2) {
            let monthFirst = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale).map { format in
                (format.firstIndex(of: "M") ?? format.startIndex) < (format.firstIndex(of: "d") ?? format.endIndex)
            } ?? true
            let typedYear = match.3.flatMap { Int($0) }.map { $0 < 100 ? $0 + 2000 : $0 } ?? year
            if let date = date(month: monthFirst ? first : second, day: monthFirst ? second : first, year: typedYear) { add(named(date), date) }
        }
        // "wed jul", "3rd wed jul", "last fri jul"
        let ordinals = ["1st": 1, "first": 1, "2nd": 2, "second": 2, "3rd": 3, "third": 3, "4th": 4, "fourth": 4, "5th": 5, "last": -1]
        let ordinal = tokens.first.flatMap { ordinals[$0] }
        let rest = ordinal == nil ? tokens : Array(tokens.dropFirst())
        if rest.count == 2, rest[0].count >= 2, let month = month(rest[1]),
           let weekday = calendar.weekdaySymbols.firstIndex(where: { $0.lowercased().hasPrefix(rest[0]) }).map({ $0 + 1 }) {
            for candidate in [year ?? calendar.component(.year, from: today), calendar.component(.year, from: today) + 1] {
                var parts = DateComponents(year: candidate, month: month, weekday: weekday, weekdayOrdinal: ordinal ?? 1)
                parts.calendar = calendar
                if ordinal == nil, let firstOfMonth = calendar.date(from: DateComponents(year: candidate, month: month, day: 1)) {
                    // Without "3rd" or "last": the first such weekday in that month that is not already past.
                    let from = max(firstOfMonth, today)
                    if calendar.component(.month, from: from) == month,
                       let next = calendar.nextDate(after: from.addingTimeInterval(-1), matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime),
                       calendar.component(.month, from: next) == month {
                        add(named(next), next)
                        break
                    }
                    continue
                }
                if let date = calendar.date(from: parts), calendar.component(.month, from: date) == month, year != nil || date >= today {
                    add(named(date), date)
                    break
                }
            }
        }
        if words.count == 1, let exact = try? DayText.day(from: phrase, now: now, calendar: calendar) {
            // A full date typed out; a phrase that is not one is simply not a date.
            add(named(exact), exact)
        }
        if "someday".hasPrefix(phrase) { add("Someday", nil) }
        return found
    }
}
