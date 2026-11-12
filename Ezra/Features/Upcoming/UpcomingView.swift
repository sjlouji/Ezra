import SwiftData
import SwiftUI

/// The next seven days one by one, then everything later by month.
struct UpcomingView: View {
    @Environment(Library.self) private var library
    private var all: [ToDo] { library.open }
    @Query(sort: \PlannerEvent.start) private var allEvents: [PlannerEvent]
    @AppStorage("showCalendarEvents") private var showsEvents = true

    private struct Month: Identifiable {
        let id: Date
        let todos: [ToDo]
    }

    var body: some View {
        let upcoming = all.filter { SmartList.upcoming.contains($0) }
        let calendar = Calendar.current
        ScreenList {
            ScreenTitle(icon: .list(.upcoming), title: SmartList.upcoming.title).plainRow()
            ForEach(1...7, id: \.self) { offset in
                let day = SmartList.day(offset)
                let events = showsEvents ? CalendarService.shared.merged(Planner.events(on: day, from: allEvents), on: day) : []
                dayHeader(day, isTomorrow: offset == 1).plainRow(bottom: 6)
                if !events.isEmpty {
                    EventsCard(events: events, onCard: false).plainRow(bottom: 6)
                }
                ToDoRows(todos: upcoming.filter { $0.startDate.map { calendar.isDate($0, inSameDayAs: day) } ?? false })
            }
            ForEach(months(of: upcoming.filter { ($0.startDate ?? .distantPast) >= SmartList.day(8) })) { month in
                GroupHeader(icon: nil, title: month.id.formatted(.dateTime.month(.wide))).plainRow(bottom: 4)
                ToDoRows(todos: month.todos, style: .dated)
            }
        }
    }

    /// The day's number, large, beside a rule with the weekday under it.
    private func dayHeader(_ day: Date, isTomorrow: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Brand.Palette.ink)
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
                Text(isTomorrow ? Brand.Words.tomorrow : day.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.Palette.secondary)
            }
            .padding(.bottom, 4)
        }
        .padding(.top, 22)
    }

    private func months(of todos: [ToDo]) -> [Month] {
        let calendar = Calendar.current
        let byMonth = Dictionary(grouping: todos) { todo in
            calendar.dateInterval(of: .month, for: todo.startDate ?? .now)?.start ?? .now
        }
        return byMonth.keys.sorted().map { month in
            Month(id: month, todos: (byMonth[month] ?? []).sorted { ($0.startDate ?? .now) < ($1.startDate ?? .now) })
        }
    }
}
