import SwiftData
import SwiftUI

/// A week on an hour grid. Events sit at their times; a to-do with a reminder time sits at that time. Drag a to-do onto
/// an hour to give it that day and time, or onto the strip above the grid to give it the day only.
struct WeekView: View {
    @Binding var mode: PlannerMode
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }
    @Query(sort: \PlannerEvent.start) private var events: [PlannerEvent]
    @AppStorage("showCalendarEvents") private var showsEvents = true
    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 46
    private let gutter: CGFloat = 46

    var body: some View {
        let days = Planner.week(containing: app.day)
        // Each day's to-dos and events are worked out once here, not again by the header and the column.
        let open = todos.filter { !$0.isCompleted && !$0.isTemplate && $0.project?.isTemplate != true }
        let planned = Dictionary(uniqueKeysWithValues: days.map { ($0, Planner.todos(on: $0, from: open)) })
        let span = DateInterval(start: days[0], end: SmartList.day(1, from: days[6]))
        let all = showsEvents ? events.filter { $0.start < span.end && $0.end > span.start }.map(\.dayEvent) + CalendarService.shared.events(in: span) : []
        let shown = Dictionary(uniqueKeysWithValues: days.map { ($0, CalendarService.events(on: $0, among: all)) })
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { day in
                    dayHeader(day, todos: planned[day] ?? [], events: shown[day] ?? [])
                }
            }
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(Planner.firstHour..<Planner.lastHour, id: \.self) { hour in
                                Text(hourLabel(hour))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Brand.Palette.secondary)
                                    .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                                    .offset(y: -6)
                                    .id(hour)
                            }
                        }
                        .frame(width: gutter)
                        ForEach(days, id: \.self) { day in
                            dayColumn(day, todos: planned[day] ?? [], events: shown[day] ?? [])
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onAppear { proxy.scrollTo(max(calendar.component(.hour, from: .now) - 2, Planner.firstHour), anchor: .top) }
            }
        }
        .padding(.horizontal, 20)
    }

    /// The day's name, and under it what has a day but no time: all-day events and to-dos without a reminder.
    private func dayHeader(_ day: Date, todos: [ToDo], events: [DayEvent]) -> some View {
        let isToday = calendar.isDateInToday(day)
        let allDay = events.filter(\.isAllDay)
        let untimed = todos.filter { timed($0, on: day) == nil }
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    app.day = day
                    mode = .day
                }
            } label: {
                HStack(spacing: 5) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isToday ? Brand.Palette.accent : Brand.Palette.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isToday ? .white : Brand.Palette.ink)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(isToday ? Brand.Palette.accent : .clear, in: .circle)
                }
            }
            .help("Open \(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
            ForEach(allDay) { event in
                chip(event.title, tint: event.tint)
            }
            ForEach(untimed.prefix(4)) { todo in
                chip(todo.title, tint: Brand.Palette.secondary, outlined: true).draggable(todo)
            }
            if untimed.count > 4 {
                Text("+\(untimed.count - 4) more").font(.system(size: 10)).foregroundStyle(Brand.Palette.secondary)
            }
        }
        .buttonStyle(.hand)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .dropTarget(.day(day))
    }

    private func dayColumn(_ day: Date, todos: [ToDo], events: [DayEvent]) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Planner.firstHour..<Planner.lastHour, id: \.self) { hour in
                    Rectangle().fill(.clear)
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) { Rectangle().fill(Brand.Palette.hairline).frame(height: 0.5) }
                        .contentShape(.rect)
                        .dropTarget(.hour(day.addingTimeInterval(TimeInterval(hour) * 3600)))
                }
            }
            ForEach(events.filter { !$0.isAllDay }) { event in
                let frame = Planner.frame(start: event.start, end: event.end, on: day, hourHeight: hourHeight)
                block(event.title, tint: event.tint, time: event.start)
                    .frame(height: frame.height - 2, alignment: .top)
                    .offset(y: frame.y + 1)
                    .allowsHitTesting(false)
            }
            ForEach(todos.filter { timed($0, on: day) != nil }) { todo in
                let start = timed(todo, on: day) ?? day
                let frame = Planner.frame(start: start, end: start.addingTimeInterval(1800), on: day, hourHeight: hourHeight)
                block(todo.title, tint: Brand.Palette.accent, time: start, isToDo: true)
                    .frame(height: frame.height - 2, alignment: .top)
                    .offset(y: frame.y + 1)
                    .onTapGesture { app.jump(to: todo) }
                    .draggable(todo)
                    .help("Drag to another time, or click to open")
            }
            if calendar.isDateInToday(day) {
                let now = Planner.frame(start: .now, end: .now, on: day, hourHeight: hourHeight)
                Rectangle().fill(Brand.Palette.deadline).frame(height: 1.5).offset(y: now.y).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Rectangle().fill(Brand.Palette.hairline).frame(width: 0.5) }
    }

    /// The moment a to-do is blocked for on `day`: its reminder, when that falls on the day.
    private func timed(_ todo: ToDo, on day: Date) -> Date? {
        todo.reminderAt.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
    }

    private func chip(_ title: String, tint: Color, outlined: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 10.5))
            .foregroundStyle(Brand.Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(outlined ? Brand.Palette.field : tint.opacity(0.18), in: .rect(cornerRadius: 4))
    }

    private func block(_ title: String, tint: Color, time: Date, isToDo: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((isToDo ? "☐ " : "") + title).font(.system(size: 10.5, weight: .semibold)).lineLimit(2)
            Text(time.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(Brand.Palette.secondary)
        }
        .foregroundStyle(Brand.Palette.ink)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(isToDo ? 0.14 : 0.2), in: .rect(cornerRadius: 5))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2.5) }
        .clipShape(.rect(cornerRadius: 5))
        .padding(.horizontal, 2)
    }

    private func hourLabel(_ hour: Int) -> String {
        (calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now).formatted(.dateTime.hour())
    }
}

/// Lets a to-do shown outside a list (a chip or a block on the week grid) be dragged onto a day or an hour.
private struct DraggableToDo: ViewModifier {
    let todo: ToDo
    @Environment(AppModel.self) private var app
    @State private var probe: ProbeView?

    func body(content: Content) -> some View {
        content
            .opacity(app.drag?.item == .todo(todo) ? 0.3 : 1)
            .background { Probe { probe = $0 } }
            .highPriorityGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { _ in
                        guard let pointer = AppModel.pointer(), let origin = probe?.windowFrame() else { return }
                        app.dragChanged(.todo(todo), at: pointer, from: origin)
                    }
                    .onEnded { _ in app.dragEnded() }
            )
    }
}

private extension View {
    func draggable(_ todo: ToDo) -> some View { modifier(DraggableToDo(todo: todo)) }
}
