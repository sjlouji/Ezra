import SwiftUI
import WidgetKit

struct ListEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// Why there is nothing to show, when reading failed.
    var problem: String?
}

/// Reads what the app last wrote. The app asks for a redraw on every change; the hourly refresh is only a safety net.
struct ListProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListEntry {
        ListEntry(date: .now, snapshot: WidgetSnapshot(updated: .now, today: [
            .init(id: UUID(), title: "Call the bank", place: "Money", day: nil, isDue: true),
            .init(id: UUID(), title: "Write the report", place: "Work", day: nil, isDue: false),
        ], upcoming: []))
    }

    func getSnapshot(in context: Context, completion: @escaping (ListEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func entry() -> ListEntry {
        do {
            return ListEntry(date: .now, snapshot: try WidgetSnapshot.read())
        } catch {
            return ListEntry(date: .now, snapshot: nil, problem: "Open Ezra once to fill this widget.")
        }
    }
}

struct ListWidgetView: View {
    let title: String
    let symbol: String
    let tint: Color
    let items: [WidgetSnapshot.Item]
    let entry: ListEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let limit = family == .systemSmall ? 4 : family == .systemMedium ? 4 : 10
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(items.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let problem = entry.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("Nothing here.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(limit)) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 1).frame(width: 11, height: 11)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(.system(size: 12)).lineLimit(1)
                        if family != .systemSmall, let caption = caption(item) {
                            Text(caption).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if item.isDue { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(.red) }
                }
            }
            if items.count > limit {
                Text("+\(items.count - limit) more").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "ezra:///show"))
    }

    private func caption(_ item: WidgetSnapshot.Item) -> String? {
        let day = item.day?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let parts = [day, item.place.isEmpty ? nil : item.place].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.ezra.today", provider: ListProvider()) { entry in
            ListWidgetView(title: "Today", symbol: "star.fill", tint: .yellow, items: entry.snapshot?.today ?? [], entry: entry)
        }
        .configurationDisplayName("Today")
        .description("What is planned or due today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UpcomingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.ezra.upcoming", provider: ListProvider()) { entry in
            ListWidgetView(title: "Upcoming", symbol: "calendar", tint: .red, items: entry.snapshot?.upcoming ?? [], entry: entry)
        }
        .configurationDisplayName("Upcoming")
        .description("What the next days hold.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct EzraWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        UpcomingWidget()
    }
}
