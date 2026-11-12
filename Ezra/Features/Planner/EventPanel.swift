import SwiftData
import SwiftUI

/// An event's page: when it is, its bucket and project, free-form notes, and the to-dos that came out of it.
struct EventPanel: View {
    @Bindable var event: PlannerEvent
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.order) private var projects: [Project]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Close", systemImage: "chevron.left") { close() }
                        .foregroundStyle(Brand.Palette.secondary)
                    Spacer()
                    Button("Delete Event", systemImage: "trash", role: .destructive) {
                        close()
                        Alerts.shared.attempt("delete the event") { try Workspace(context: context).delete(event) }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Brand.Palette.secondary)
                }
                .buttonStyle(.hand)
                .font(Brand.Fonts.subtitle)

                TextField("Event", text: $event.title, axis: .vertical)
                    .font(.system(size: 17, weight: .bold))

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Image(systemName: "clock").accessibilityLabel("Starts")
                        DatePicker("Start", selection: startBinding, displayedComponents: event.isAllDay ? .date : [.date, .hourAndMinute])
                    }
                    if !event.isAllDay {
                        GridRow {
                            Image(systemName: "arrow.right").accessibilityLabel("Ends")
                            DatePicker("End", selection: endBinding, displayedComponents: .hourAndMinute)
                        }
                    }
                    GridRow {
                        Image(systemName: "sun.max").accessibilityHidden(true)
                        HStack(spacing: 6) {
                            Toggle("All day", isOn: $event.isAllDay).toggleStyle(.checkbox)
                            Text("All day")
                        }
                    }
                    GridRow {
                        ListIcon(.pie(progress: event.project?.progress ?? 0, tint: Brand.Palette.secondary), size: 14)
                        Picker("Project", selection: $event.project) {
                            Text("No project").tag(Project?.none)
                            ForEach(projects.filter { !$0.isCompleted || $0 == event.project }) { project in
                                Text(project.name).tag(Project?.some(project))
                            }
                        }
                        .fixedSize()
                    }
                }
                .labelsHidden()
                .font(Brand.Fonts.subtitle)
                .foregroundStyle(Brand.Palette.secondary)

                BucketChips(selection: $event.bucket)

                VStack(alignment: .leading, spacing: 10) {
                    TextField(Brand.Words.notes, text: $event.noteBody, axis: .vertical)
                        .font(.system(size: 13))
                        .lineLimit(4...24)
                    ForEach(event.openToDos) { todo in
                        ToDoRow(todo: todo, style: todo.when == .dated ? .dated : .standard)
                    }
                    Button("Add To-Do", systemImage: "plus") { app.newToDo(event: event, inBacklog: true) }
                        .buttonStyle(.hand)
                        .font(Brand.Fonts.label)
                        .foregroundStyle(Brand.Palette.accent)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.Palette.field.opacity(0.7), in: .rect(cornerRadius: 10))
            }
            .textFieldStyle(.plain)
            .foregroundStyle(Brand.Palette.ink)
            .padding(18)
        }
        .background(Brand.Palette.page)
        .onExitCommand { close() }
    }

    /// Moving the start keeps the event's length.
    private var startBinding: Binding<Date> {
        Binding(get: { event.start }) { newStart in
            let length = max(event.end.timeIntervalSince(event.start), 900)
            event.start = newStart
            event.end = newStart.addingTimeInterval(length)
        }
    }

    /// The end is a time on the start's day, and never before the start.
    private var endBinding: Binding<Date> {
        Binding(get: { event.end }) { newEnd in
            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: newEnd)
            let sameDay = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: event.start) ?? newEnd
            event.end = max(sameDay, event.start.addingTimeInterval(900))
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { app.openEvent = nil }
    }
}
