import SwiftData
import SwiftUI

/// The planner. By day: a week strip over three columns (the calendar, the day's to-dos by bucket, an event's note). By month or year: a calendar grid.
struct PlannerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }
    @Query(sort: \PlannerEvent.start) private var events: [PlannerEvent]
    @State private var pane = Pane.tasks
    @AppStorage("planner.mode") private var mode = PlannerMode.day

    private enum Pane: String, CaseIterable {
        case events = "Events"
        case backlog = "Backlog"
        case tasks = "Tasks"
    }

    var body: some View {
        VStack(spacing: 0) {
            PlannerBar(mode: $mode)
            switch mode {
            case .day:
                WeekStrip()
                Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
                GeometryReader { proxy in
                    columns(for: proxy.size.width)
                }
            case .week:
                WeekView(mode: $mode)
            case .month:
                MonthView(mode: $mode)
            case .year:
                YearView(mode: $mode)
            }
        }
        .background(Brand.Palette.page)
    }

    /// Wide: calendar, to-dos and the open event's note side by side. Medium: two of them. Narrow: one at a time, with tabs.
    @ViewBuilder
    private func columns(for width: CGFloat) -> some View {
        let grid = DayGridView(day: app.day, events: Planner.events(on: app.day, from: events))
            .overlay(alignment: .topTrailing) {
                Button("New Event", systemImage: "plus") { newEvent() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hand)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.Palette.secondary)
                    .padding(8)
                    .help("New Event")
            }
        if width < 560 {
            if let event = app.openEvent {
                EventPanel(event: event).id(event.persistentModelID)
            } else {
                VStack(spacing: 0) {
                    tabs(Pane.allCases)
                    if pane == .events { grid } else { taskList }
                }
            }
        } else {
            HStack(spacing: 0) {
                grid.frame(maxWidth: .infinity)
                Rectangle().fill(Brand.Palette.hairline).frame(width: 1)
                if let event = app.openEvent, width < 900 {
                    EventPanel(event: event).id(event.persistentModelID).frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        tabs([.backlog, .tasks])
                        taskList
                    }
                    .frame(maxWidth: .infinity)
                    if let event = app.openEvent {
                        Rectangle().fill(Brand.Palette.hairline).frame(width: 1)
                        EventPanel(event: event).id(event.persistentModelID).frame(width: 320)
                    }
                }
            }
        }
    }

    /// The pane switch. Where the calendar has its own column there is no Events tab, and Tasks stands in for it.
    private func tabs(_ options: [Pane]) -> some View {
        let selected = options.contains(pane) ? pane : .tasks
        return HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button(option.rawValue) {
                    withAnimation(.snappy(duration: 0.2)) { pane = option }
                }
                .buttonStyle(.hand)
                .font(Brand.Fonts.label)
                .foregroundStyle(selected == option ? .white : Brand.Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected == option ? Brand.Palette.plannerTab : Brand.Palette.field, in: .rect(cornerRadius: 7))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var taskList: some View {
        let shown = pane == .backlog ? Planner.backlog(from: todos) : Planner.todos(on: app.day, from: todos)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Bucket.allCases) { bucket in
                    BucketCard(bucket: bucket, todos: shown.filter { $0.bucket == bucket }, inBacklog: pane == .backlog)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { app.closeCard() }
        }
    }

    /// A one-hour event at the next full hour of the shown day (9 AM on other days), opened for editing.
    private func newEvent() {
        let calendar = Calendar.current
        let hour = calendar.isDateInToday(app.day) ? min(calendar.component(.hour, from: .now) + 1, Planner.lastHour - 1) : 9
        Alerts.shared.attempt("create the event") {
            let start = app.day.addingTimeInterval(TimeInterval(hour) * 3600)
            let event = try Workspace(context: context).addEvent(title: "New Event", start: start)
            withAnimation(.snappy(duration: 0.25)) { app.openEvent = event }
        }
    }
}

/// The month, and the seven days of the shown week; the selected day is outlined.
private struct WeekStrip: View {
    @Environment(AppModel.self) private var app
    private let calendar = Calendar.current

    var body: some View {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: app.day)?.start ?? app.day
        let days = (0..<7).map { SmartList.day($0, from: weekStart) }
        ViewThatFits(in: .horizontal) {
            strip(days, showsMonth: true)
            strip(days, showsMonth: false)
        }
        .foregroundStyle(Brand.Palette.ink)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func strip(_ days: [Date], showsMonth: Bool) -> some View {
        HStack(spacing: showsMonth ? 14 : 6) {
            if showsMonth {
                // The screen's title: "Today" with its star, or the weekday of whichever day is shown.
                let isToday = calendar.isDateInToday(app.day)
                HStack(spacing: 9) {
                    ListIcon(isToday ? .star : .list(.upcoming), size: 23)
                    Text(isToday ? SmartList.today.title : app.day.formatted(.dateTime.weekday(.wide)))
                        .font(Brand.Fonts.title)
                    Text(app.day.formatted(.dateTime.month(.wide).day()))
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.secondary)
                        .padding(.top, 5)
                }
                .fixedSize()
                Spacer(minLength: 16)
            }
            stepper("Previous week", "chevron.left", by: -7)
            HStack(spacing: showsMonth ? 4 : 0) {
                ForEach(days, id: \.self) { day in
                    dayCell(day).frame(minWidth: showsMonth ? 40 : 28, maxWidth: 40)
                }
            }
            stepper("Next week", "chevron.right", by: 7)
            if !showsMonth { Spacer(minLength: 0) }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: app.day)
        let isToday = calendar.isDateInToday(day)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                app.day = day
                app.openEvent = nil
            }
        } label: {
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: .semibold))
                Text(day.formatted(.dateTime.weekday(.short)).uppercased())
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Brand.Palette.plannerDay : isToday ? Brand.Palette.ink : Brand.Palette.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(isSelected ? Brand.Palette.plannerDay.opacity(0.08) : .clear, in: .rect(cornerRadius: 9))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Brand.Palette.plannerDay, lineWidth: 1.5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.hand)
        .dropTarget(.day(day))
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func stepper(_ label: String, _ symbol: String, by days: Int) -> some View {
        Button(label, systemImage: symbol) {
            withAnimation(.snappy(duration: 0.2)) {
                app.day = SmartList.day(days, from: app.day)
                app.openEvent = nil
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.hand)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Brand.Palette.secondary)
    }
}

/// One bucket's to-dos on a tinted card, with a plus that adds straight into it.
private struct BucketCard: View {
    let bucket: Bucket
    let todos: [ToDo]
    let inBacklog: Bool
    @Environment(AppModel.self) private var app
    @State private var runID = UUID()

    var body: some View {
        let _ = app.runs[runID] = todos
        // Rows are made as they scroll into view; a bucket can hold hundreds.
        LazyVStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BucketBadge(bucket: bucket)
                Text(bucket.title).font(Brand.Fonts.rowBold)
                Spacer()
                Button("Add to \(bucket.title)", systemImage: "plus.square") {
                    app.newToDo(bucket: bucket, inBacklog: inBacklog)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.hand)
                .font(.system(size: 15))
                .foregroundStyle(Brand.Palette.secondary)
            }
            ForEach(todos) { todo in
                ToDoRow(todo: todo, run: RunRef(id: runID, fallback: .bucket(bucket, backlog: inBacklog, before: todo)))
                    .padding(.horizontal, 12)
                    .background(Brand.Palette.page, in: .rect(cornerRadius: 8))
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if todos.isEmpty {
                Text("Nothing here")
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                    .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(bucket.tint.opacity(0.07), in: .rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(bucket.tint.opacity(0.18), lineWidth: 1) }
        .dropTarget(.bucket(bucket, backlog: inBacklog, before: nil))
        .animation(AppModel.spring, value: todos.map(\.persistentModelID))
    }
}
