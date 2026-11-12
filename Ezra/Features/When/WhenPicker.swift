import SwiftData
import SwiftUI

/// The dark card for choosing when to do a to-do, or (as "Deadline") the day it is due.
struct WhenPicker: View {
    let picker: AppModel.OpenPicker
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private let calendar = Calendar.current
    private var isDeadline: Bool { picker.mode == .deadline }
    private var todo: ToDo { picker.todo }
    private var today: Date { calendar.startOfDay(for: .now) }
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var reminderText = ""
    @State private var addsReminder = false

    var body: some View {
        VStack(spacing: 8) {
            Text(isDeadline ? Brand.Words.deadline : Brand.Words.when)
                .font(Brand.Fonts.rowBold)
                .padding(.bottom, 2)
            searchField
            if suggestions.isEmpty {
                browse
            } else {
                ForEach(suggestions, id: \.label) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
        .foregroundStyle(Brand.Palette.pickerText)
        .padding(16)
        .frame(width: 272)
        .background(Brand.Palette.pickerCard, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .onExitCommand { app.closePicker() }
    }

    /// Type a day instead of picking one: "tom", "fri", "in 3 weeks".
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.Palette.pickerText.opacity(0.5))
            TextField(isDeadline ? "Deadline" : "When", text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { if let first = suggestions.first { choose(first) } }
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 7))
        .onAppear { queryFocused = true }
    }

    /// What the typed phrase could mean. A deadline is always a day, so it gets no Someday or This Evening.
    private var suggestions: [WhenSuggestion] {
        WhenPhrase.suggestions(for: query).filter { !isDeadline || ($0.date != nil && !$0.evening) }
    }

    private func suggestionRow(_ suggestion: WhenSuggestion) -> some View {
        let isFirst = suggestion == suggestions.first
        let icon: ListIcon.Kind = suggestion.date == nil ? .list(.someday)
            : suggestion.evening ? .moon
            : calendar.isDate(suggestion.date ?? today, inSameDayAs: today) ? .star : .list(.upcoming)
        return Button {
            choose(suggestion)
        } label: {
            HStack(spacing: 9) {
                ListIcon(icon, size: 15)
                Text(suggestion.label).font(Brand.Fonts.rowBold)
                Spacer()
                if let date = suggestion.date {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(Brand.Fonts.subtitle)
                        .opacity(0.7)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isFirst ? Brand.Palette.magicPlus : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
    }

    private func choose(_ suggestion: WhenSuggestion) {
        if isDeadline {
            setDeadline(suggestion.date)
        } else if let date = suggestion.date {
            plan(.on(date, evening: suggestion.evening), reminder: suggestion.reminderDate)
        } else {
            plan(.someday)
        }
    }

    /// The quick choices and the five-week calendar.
    @ViewBuilder
    private var browse: some View {
        if !isDeadline {
            option(.star, SmartList.today.title, selected: isPlanned(today) && !todo.evening) { plan(.on(today)) }
            option(.moon, Brand.Words.thisEvening, selected: isPlanned(today) && todo.evening) { plan(.on(today, evening: true)) }
        }
        calendarGrid
        if !isDeadline {
            option(.list(.someday), SmartList.someday.title, selected: todo.when == .someday) { plan(.someday) }
        }
        if !isDeadline { reminderRow }
        Button(Brand.Words.clear) {
            if isDeadline { setDeadline(nil) } else { plan(.unscheduled) }
        }
        .buttonStyle(.hand)
        .font(Brand.Fonts.label)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.white.opacity(0.1), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private var calendarGrid: some View {
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<35).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.Palette.pickerText.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(days, id: \.self, content: dayCell)
            }
        }
        .padding(.vertical, 4)
    }

    private func dayCell(_ day: Date) -> some View {
        let isPast = day < today
        let isSelected = isDeadline ? todo.deadline.map { calendar.isDate($0, inSameDayAs: day) } ?? false : isPlanned(day)
        let number = calendar.component(.day, from: day)
        return Button {
            if isDeadline { setDeadline(day) } else { plan(.on(day)) }
        } label: {
            VStack(spacing: 0) {
                if number == 1 {
                    Text(day.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 8, weight: .bold))
                }
                if day == today, !isSelected {
                    ListIcon(.star, size: 13)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: isSelected ? .bold : .regular))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                isSelected ? (isDeadline ? Brand.Palette.deadline : Brand.Palette.accent) : .clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
        .opacity(isPast ? 0.3 : 1)
        .disabled(isPast)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    }

    private func option(_ icon: ListIcon.Kind, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ListIcon(icon, size: 17)
                Text(title).font(Brand.Fonts.rowBold)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
    }

    private func isPlanned(_ day: Date) -> Bool {
        todo.when == .dated && (todo.startDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
    }

    /// Plans the to-do. Its reminder follows it: a new time if one was typed, the same time on the new day
    /// if it already had one, and none once it has no day.
    private func plan(_ schedule: Schedule, reminder: Date? = nil) {
        Alerts.shared.attempt("reschedule the to-do") {
            let workspace = Workspace(context: context)
            var remind = reminder
            if remind == nil, case .on(let day, _) = schedule, let old = todo.reminderAt {
                let time = calendar.dateComponents([.hour, .minute], from: old)
                remind = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day)
            }
            try workspace.schedule(todo, schedule)
            try workspace.setReminder(todo, at: remind)
        }
        app.closePicker()
    }

    /// A reminder on the day the to-do is planned for (today, if it has no day yet).
    private var reminderRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "bell").frame(width: 17)
            if let reminder = todo.reminderAt, !addsReminder {
                Text(reminder.formatted(.dateTime.hour().minute())).font(Brand.Fonts.rowBold)
                Spacer()
                Button("Remove Reminder", systemImage: "xmark") {
                    Alerts.shared.attempt("remove the reminder") { try Workspace(context: context).setReminder(todo, at: nil) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.hand)
                .font(.system(size: 10, weight: .bold))
            } else if addsReminder {
                TextField("Time, for example 9am", text: $reminderText)
                    .textFieldStyle(.plain)
                    .font(Brand.Fonts.rowBold)
                    .onSubmit(setReminder)
            } else {
                Button("Add Reminder") { addsReminder = true }
                    .buttonStyle(.hand)
                    .font(Brand.Fonts.rowBold)
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func setReminder() {
        guard let minutes = WhenPhrase.time(reminderText.trimmed.lowercased().replacingOccurrences(of: " ", with: ""), allowsBareHour: true) else {
            return Alerts.shared.message = "“\(reminderText)” is not a time. Try 9am, 2:30pm or 14:30."
        }
        Alerts.shared.attempt("set the reminder") {
            let workspace = Workspace(context: context)
            let day = todo.when == .dated ? (todo.startDate ?? today) : today
            if todo.when != .dated { try workspace.schedule(todo, .on(day)) }
            try workspace.setReminder(todo, at: calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: day)))
        }
        (addsReminder, reminderText) = (false, "")
    }

    private func setDeadline(_ day: Date?) {
        Alerts.shared.attempt("set the deadline") { try Workspace(context: context).setDeadline(todo, day) }
        app.closePicker()
    }
}
