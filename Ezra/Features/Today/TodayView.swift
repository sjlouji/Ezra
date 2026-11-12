import SwiftData
import SwiftUI

/// Today: the day's events, what is planned or due, then This Evening.
struct TodayView: View {
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app
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
            let daytime = shown.filter { !$0.evening }
            // With everything in the evening there is no row to drop on, so the day offers a place while a to-do is dragged.
            if daytime.isEmpty, !evening.isEmpty, app.isDraggingToDo {
                Text("Drop here for earlier today")
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .dropTarget(.evening(false))
                    .plainRow(bottom: 6)
            }
            ToDoRows(todos: daytime, section: .evening(false))
            // While a to-do is being dragged the evening's header is there to drop on, even with nothing under it yet.
            if !evening.isEmpty || app.isDraggingToDo {
                GroupHeader(icon: .moon, title: Brand.Words.thisEvening).dropTarget(.evening(true)).plainRow(bottom: 6)
                ToDoRows(todos: evening, section: .evening(true))
            }
        }
    }
}
