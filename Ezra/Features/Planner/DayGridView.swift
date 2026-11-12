import SwiftData
import SwiftUI

/// One day's events on an hour grid. Click an event to open its note; double-click an empty hour to add one.
struct DayGridView: View {
    let day: Date
    let events: [PlannerEvent]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private let hourHeight: CGFloat = 50
    private let gutter: CGFloat = 54
    private let calendar = Calendar.current

    var body: some View {
        let allDay = events.filter(\.isAllDay)
        VStack(spacing: 0) {
            if !allDay.isEmpty {
                VStack(spacing: 4) {
                    ForEach(allDay) { event in
                        block(event, subtitle: "All day").frame(height: 26)
                    }
                }
                .padding(.leading, gutter)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
                Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hours
                        ForEach(events.filter { !$0.isAllDay }) { event in
                            let frame = Planner.frame(start: event.start, end: event.end, on: day, hourHeight: hourHeight)
                            block(event, subtitle: timeRange(event))
                                .frame(height: frame.height - 3, alignment: .top)
                                .padding(.leading, gutter)
                                .padding(.trailing, 14)
                                .offset(y: frame.y + 1)
                        }
                        if calendar.isDateInToday(day) {
                            nowLine
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onAppear { proxy.scrollTo(max(calendar.component(.hour, from: .now) - 2, Planner.firstHour), anchor: .top) }
            }
        }
    }

    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(Planner.firstHour..<Planner.lastHour, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(hourLabel(hour))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.Palette.secondary)
                        .frame(width: gutter - 12, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .contentShape(.rect)
                .onTapGesture(count: 2) { addEvent(atHour: hour) }
                .id(hour)
            }
        }
    }

    private var nowLine: some View {
        let frame = Planner.frame(start: .now, end: .now, on: day, hourHeight: hourHeight)
        return HStack(spacing: 0) {
            Circle().fill(Brand.Palette.ink).frame(width: 6, height: 6)
            Rectangle().fill(Brand.Palette.ink).frame(height: 1)
        }
        .padding(.leading, gutter - 3)
        .offset(y: frame.y - 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func block(_ event: PlannerEvent, subtitle: String) -> some View {
        let isOpen = app.openEvent == event
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(subtitle).foregroundStyle(Brand.Palette.ink.opacity(0.7))
                Text(event.title.isEmpty ? "Untitled" : event.title).fontWeight(.semibold)
                Spacer(minLength: 4)
                if !event.noteBody.isEmpty || !(event.todos ?? []).isEmpty {
                    Image(systemName: "note.text").foregroundStyle(event.bucket.tint).accessibilityLabel("Has a note")
                }
            }
            .lineLimit(1)
            if let project = event.project {
                Text(project.name).foregroundStyle(Brand.Palette.secondary).lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Brand.Palette.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(event.bucket.tint.opacity(isOpen ? 0.3 : 0.17), in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(event.bucket.tint.opacity(isOpen ? 0.9 : 0.3), lineWidth: 1) }
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) { app.openEvent = isOpen ? nil : event }
        }
        .pointerStyle(.link)
        .accessibilityAddTraits(.isButton)
    }

    private func addEvent(atHour hour: Int) {
        Alerts.shared.attempt("create the event") {
            let start = calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(hour) * 3600)
            let event = try Workspace(context: context).addEvent(title: "New Event", start: start)
            withAnimation(.snappy(duration: 0.25)) { app.openEvent = event }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    private func timeRange(_ event: PlannerEvent) -> String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(event.start.formatted(style)) – \(event.end.formatted(style))"
    }
}
