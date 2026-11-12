import SwiftData
import SwiftUI

/// How much of the calendar the planner shows.
enum PlannerMode: String, CaseIterable, Identifiable {
    case day, week, month, year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The top of the planner: where you are (with arrows and a way to jump far), Today, and the Day / Month / Year switch.
struct PlannerBar: View {
    @Binding var mode: PlannerMode
    @Environment(AppModel.self) private var app
    @State private var jumping = false
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 10) {
            if mode != .day {
                Button(title) { jumping = true }
                    .font(Brand.Fonts.title)
                    .foregroundStyle(Brand.Palette.ink)
                    .help("Jump to another month or year")
                    .popover(isPresented: $jumping, arrowEdge: .bottom) { JumpPicker(mode: mode) { jumping = false } }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.Palette.secondary)
                    .allowsHitTesting(false)
                step("Previous \(mode.rawValue)", "chevron.left", by: -1)
                step("Next \(mode.rawValue)", "chevron.right", by: 1)
            }
            Spacer(minLength: 8)
            Button("Today") { go(to: .now) }
                .font(Brand.Fonts.label)
                .foregroundStyle(calendar.isDateInToday(app.day) ? Brand.Palette.secondary : Brand.Palette.accent)
                .help("Go to today")
            Picker("View", selection: $mode) {
                ForEach(PlannerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .buttonStyle(.hand)
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, mode == .day ? 0 : 12)
    }

    private var title: String {
        switch mode {
        case .week:
            let days = Planner.week(containing: app.day)
            guard let first = days.first, let last = days.last else { return "" }
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(sameMonth ? .dateTime.day() : .dateTime.month(.abbreviated).day())), \(last.formatted(.dateTime.year()))"
        case .year: return app.day.formatted(.dateTime.year())
        case .day, .month: return app.day.formatted(.dateTime.month(.wide).year())
        }
    }

    private func step(_ label: String, _ symbol: String, by value: Int) -> some View {
        let unit: Calendar.Component = mode == .week ? .weekOfYear : mode == .month ? .month : .year
        return Button(label, systemImage: symbol) { go(to: Planner.shifted(app.day, by: value, unit)) }
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Brand.Palette.secondary)
    }

    private func go(to day: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            app.day = calendar.startOfDay(for: day)
            app.openEvent = nil
        }
    }
}

/// Goes straight to any month of any year: a year stepper over the twelve months.
private struct JumpPicker: View {
    let mode: PlannerMode
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @State private var year = 0
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Ten years back", systemImage: "chevron.left.2") { year -= 10 }
                Button("Previous year", systemImage: "chevron.left") { year -= 1 }
                Spacer()
                Button(String(year)) { pick(month: mode == .year ? calendar.component(.month, from: app.day) : nil) }
                    .font(Brand.Fonts.rowBold)
                    .labelStyle(.titleOnly)
                    .help(mode == .year ? "Show this year" : "Year")
                    .disabled(mode != .year)
                Spacer()
                Button("Next year", systemImage: "chevron.right") { year += 1 }
                Button("Ten years on", systemImage: "chevron.right.2") { year += 10 }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(Brand.Palette.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(1...12, id: \.self) { month in
                    let isShown = year == calendar.component(.year, from: app.day) && month == calendar.component(.month, from: app.day)
                    Button {
                        pick(month: month)
                    } label: {
                        Text(calendar.shortMonthSymbols[month - 1])
                            .font(Brand.Fonts.label)
                            .foregroundStyle(isShown ? .white : Brand.Palette.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(isShown ? Brand.Palette.accent : Brand.Palette.field, in: .rect(cornerRadius: 7))
                            .contentShape(.rect)
                    }
                }
            }
        }
        .buttonStyle(.hand)
        .padding(14)
        .frame(width: 250)
        .onAppear { year = calendar.component(.year, from: app.day) }
    }

    /// Shows the chosen month of the year on the stepper, on the day number already shown where that month has one.
    private func pick(month: Int?) {
        var parts = calendar.dateComponents([.day], from: app.day)
        (parts.year, parts.month) = (year, month ?? calendar.component(.month, from: app.day))
        let days = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: parts.year, month: parts.month)) ?? app.day)
        parts.day = min(parts.day ?? 1, days?.count ?? 28)
        guard let day = calendar.date(from: parts) else { return Log.store.error("No such month: \(year)-\(month ?? 0)") }
        withAnimation(.snappy(duration: 0.2)) { app.day = day }
        done()
    }
}

/// A month as a grid of days. Each day shows its events and to-dos; clicking one opens that day, and a to-do can be dropped on it.
struct MonthView: View {
    @Binding var mode: PlannerMode
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }
    @Query(sort: \PlannerEvent.start) private var events: [PlannerEvent]
    @AppStorage("showCalendarEvents") private var showsEvents = true
    private let calendar = Calendar.current

    var body: some View {
        let days = Planner.monthGrid(for: app.day)
        // Sorted into days once, not searched through again for each of the 42 cells.
        let open = todos.filter { !$0.isCompleted && !$0.isTemplate && $0.project?.isTemplate != true }
        let planned = Dictionary(grouping: open.filter { $0.when == .dated && $0.startDate != nil }) { calendar.startOfDay(for: $0.startDate ?? .now) }
        let due = Dictionary(grouping: open.filter { $0.deadline != nil }) { calendar.startOfDay(for: $0.deadline ?? .now) }
        // Every event of the six weeks, fetched once.
        let span = DateInterval(start: days[0], end: SmartList.day(1, from: days[41]))
        let shownEvents = showsEvents
            ? events.filter { $0.start < span.end && $0.end > span.start }.map(\.dayEvent) + CalendarService.shared.events(in: span) : []
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.Palette.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 6)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<6, id: \.self) { week in
                    GridRow {
                        ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                            // Today also carries what is overdue or left over, as the Today list does.
                            let onDay = calendar.isDateInToday(day) ? Planner.todos(on: day, from: open) : planned[day] ?? []
                            cell(
                                day, planned: onDay, due: (due[day] ?? []).filter { !onDay.contains($0) },
                                dayEvents: CalendarService.events(on: day, among: shownEvents)
                            )
                        }
                    }
                }
            }
            .overlay { Rectangle().strokeBorder(Brand.Palette.hairline) }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private func cell(_ day: Date, planned: [ToDo], due: [ToDo], dayEvents: [DayEvent]) -> some View {
        let inMonth = calendar.isDate(day, equalTo: app.day, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let lines: [(symbol: String, tint: Color, text: String)] =
            dayEvents.map { ("circle.fill", $0.tint, $0.title) }
            + due.map { ("flag.fill", Brand.Palette.deadline, $0.title) }
            + planned.map { ("square", Brand.Palette.secondary, $0.title) }
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                app.day = day
                mode = .day
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? .white : inMonth ? Brand.Palette.ink : Brand.Palette.secondary.opacity(0.6))
                    .frame(minWidth: 20, minHeight: 20)
                    .background(isToday ? Brand.Palette.accent : .clear, in: .circle)
                ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 4) {
                        Image(systemName: line.symbol).font(.system(size: 6)).foregroundStyle(line.tint)
                        Text(line.text).font(.system(size: 10.5)).foregroundStyle(Brand.Palette.ink).lineLimit(1)
                    }
                }
                if lines.count > 3 {
                    Text("+\(lines.count - 3) more").font(.system(size: 10)).foregroundStyle(Brand.Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            .opacity(inMonth ? 1 : 0.55)
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
        .overlay { Rectangle().strokeBorder(Brand.Palette.hairline, lineWidth: 0.5) }
        .dropTarget(.day(day))
        .help("Open \(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
        .accessibilityLabel("\(day.formatted(.dateTime.month(.wide).day())), \(lines.count) items")
    }
}

/// A year as twelve small months. Days with something on them carry a dot; clicking a month or a day goes there.
struct YearView: View {
    @Binding var mode: PlannerMode
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }
    @Query private var events: [PlannerEvent]
    @AppStorage("showCalendarEvents") private var showsEvents = true
    private let calendar = Calendar.current

    var body: some View {
        let months = Planner.months(ofYearContaining: app.day)
        var load = Planner.load(todos: todos, events: events)
        if showsEvents, let year = calendar.dateInterval(of: .year, for: app.day) {
            load.merge(CalendarService.shared.eventCounts(in: year), uniquingKeysWith: +)
        }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 22, alignment: .top)], spacing: 22) {
                ForEach(months, id: \.self) { month in
                    miniMonth(month, load: load)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private func miniMonth(_ month: Date, load: [Date: Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(month.formatted(.dateTime.month(.wide))) { open(month, as: .month) }
                .font(Brand.Fonts.rowBold)
                .foregroundStyle(calendar.isDate(month, equalTo: .now, toGranularity: .month) ? Brand.Palette.accent : Brand.Palette.ink)
                .help("Open \(month.formatted(.dateTime.month(.wide).year()))")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(Planner.monthGrid(for: month), id: \.self) { day in
                    if calendar.isDate(day, equalTo: month, toGranularity: .month) {
                        dayButton(day, count: load[day] ?? 0)
                    } else {
                        Color.clear.frame(height: 22)
                    }
                }
            }
        }
        .buttonStyle(.hand)
    }

    private func dayButton(_ day: Date, count: Int) -> some View {
        let isToday = calendar.isDateInToday(day)
        return Button {
            open(day, as: .day)
        } label: {
            VStack(spacing: 0) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 10.5, weight: isToday || count > 0 ? .semibold : .regular))
                    .foregroundStyle(isToday ? .white : count > 0 ? Brand.Palette.ink : Brand.Palette.secondary)
                    .frame(width: 17, height: 17)
                    .background(isToday ? Brand.Palette.accent : .clear, in: .circle)
                Circle().fill(count > 0 ? Brand.Palette.accent.opacity(min(0.35 + Double(count) * 0.15, 1)) : .clear).frame(width: 3.5, height: 3.5)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(.rect)
        }
        .dropTarget(.day(day))
        .help(count > 0 ? "\(day.formatted(.dateTime.month(.wide).day())): \(count) items" : day.formatted(.dateTime.month(.wide).day()))
    }

    private func open(_ day: Date, as newMode: PlannerMode) {
        withAnimation(.snappy(duration: 0.2)) {
            app.day = day
            mode = newMode
        }
    }
}
