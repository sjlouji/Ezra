import SwiftData
import SwiftUI

/// Today: the day's events, what is planned or due, then This Evening.
struct TodayView: View {
    @Environment(Library.self) private var library
    private var all: [ToDo] { library.open }
    @Query(sort: \PlannerEvent.start) private var allEvents: [PlannerEvent]
    @AppStorage("showCalendarEvents") private var showsEvents = true
    @State private var tag: String?

    var body: some View {
        let today = all.filter { SmartList.today.contains($0) }
        let tags = Set(today.flatMap(\.tags)).sorted()
        let shown = today.filter { tag == nil || $0.tags.contains(tag ?? "") }
        let evening = shown.filter(\.evening)
        let events = showsEvents ? CalendarService.shared.merged(Planner.events(on: .now, from: allEvents), on: .now) : []
        ScreenList {
            ScreenTitle(icon: .list(.today), title: SmartList.today.title).plainRow()
            BriefingCard(briefing: DailyBriefing.make(todos: all, events: events)).plainRow(bottom: 10)
            if !tags.isEmpty {
                TagFilterBar(tags: tags, selection: $tag).plainRow()
            }
            if !events.isEmpty {
                EventsCard(events: events).plainRow(bottom: 14)
            }
            if today.isEmpty {
                EmptyRow(text: "Nothing planned for today").plainRow()
            }
            ToDoRows(todos: shown.filter { !$0.evening })
            if !evening.isEmpty {
                GroupHeader(icon: .moon, title: Brand.Words.thisEvening).plainRow(bottom: 6)
                ToDoRows(todos: evening)
            }
        }
    }
}
