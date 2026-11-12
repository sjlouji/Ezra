import SwiftData
import SwiftUI

/// One turn in the chat. A reply is a timeline: what the assistant said and did, in order, then its closing words.
struct MessageBubble: View {
    let message: ChatModel.Message
    let isStreaming: Bool
    /// Given for the newest reply only: what to do when one of its suggestions is clicked.
    var followUp: ((String) -> Void)?

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if message.role == .user {
                // What the user attached to this message.
                ForEach(message.steps) { file in
                    if let image = file.image.flatMap(NSImage.init(data:)) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 160)
                            .clipShape(.rect(cornerRadius: 8))
                            .accessibilityLabel(file.detail)
                    }
                    Label(file.detail, systemImage: file.image == nil ? "paperclip" : "photo")
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Brand.Palette.sidebar, in: .capsule)
                        .help("\(file.result.count.formatted()) characters of text were read from this file")
                }
            } else {
                // Which model wrote this, when several answer the same message.
                if let model = message.steps.first(where: { $0.tool == ChatStep.engine }) {
                    Text(model.label).font(Brand.Fonts.label).foregroundStyle(Brand.Palette.secondary)
                }
                // Everything in the order it happened: what it said, each thing it did, and what that produced.
                ForEach(message.steps) { step in
                    if step.tool == ChatStep.narration {
                        ReplyText(text: step.result)
                    } else if !ChatStep.hidden.contains(step.tool), step.plan == nil {
                        StepRow(step: step)
                    }
                    if let table = step.table { ChatTableView(table: table) }
                    if let page = step.page { ChatPageView(page: page) }
                }
                // The plan as it stood at its latest update, with the step in hand marked while work goes on.
                if let plan = message.steps.last(where: { $0.plan != nil })?.plan {
                    PlanCard(plan: plan, isWorking: isStreaming)
                }
            }
            ForEach(message.changes, id: \.self) { change in
                Label(change, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if message.role == .failure {
                Label(message.text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if !message.text.isEmpty {
                ReplyText(text: message.text)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        message.role == .user ? AnyShapeStyle(Brand.Palette.accent.opacity(0.14)) : AnyShapeStyle(Brand.Palette.field.opacity(0.7)),
                        in: .rect(cornerRadius: 10)
                    )
            }
            if let followUp, !isStreaming, let suggestions = message.steps.first(where: { $0.tool == ChatStep.followUps }) {
                ForEach(suggestions.detail.components(separatedBy: " | "), id: \.self) { suggestion in
                    Button {
                        followUp(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "arrow.turn.down.right")
                            .font(Brand.Fonts.subtitle)
                            .foregroundStyle(Brand.Palette.accent)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 9)
                            .background(Brand.Palette.accent.opacity(0.08), in: .capsule)
                    }
                    .buttonStyle(.hand)
                    .help("Ask this next")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

/// A table of to-dos in the chat. Rows are live: tick one off, reschedule it, or click its title to go to it.
struct ChatTableView: View {
    let table: ChatTable
    @Query private var todos: [ToDo]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    init(table: ChatTable) {
        self.table = table
        let ids = table.todos
        _todos = Query(filter: #Predicate<ToDo> { ids.contains($0.uuid) })
    }

    /// The rows in the order the assistant gave them; a to-do deleted since then is left out.
    private var rows: [ToDo] {
        table.todos.compactMap { id in todos.first { $0.uuid == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(table.title, systemImage: "tablecells").font(Brand.Fonts.rowBold).foregroundStyle(Brand.Palette.ink)
                Spacer()
                Text("\(rows.filter { !$0.isCompleted }.count) open").font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ForEach(rows) { todo in
                Divider().overlay(Brand.Palette.hairline)
                row(todo)
            }
            if rows.count < table.todos.count {
                Divider().overlay(Brand.Palette.hairline)
                Text("\(table.todos.count - rows.count) deleted since")
                    .font(Brand.Fonts.subtitle)
                    .foregroundStyle(Brand.Palette.secondary)
                    .padding(10)
            }
        }
        .background(Brand.Palette.page, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Brand.Palette.hairline))
    }

    private func row(_ todo: ToDo) -> some View {
        HStack(spacing: 8) {
            Button {
                change("change the to-do") { try $0.setCompleted(todo, !todo.isCompleted) }
            } label: {
                CheckBox(checked: todo.isCompleted)
            }
            .help(todo.isCompleted ? "Mark as not done" : "Mark as done")
            Button {
                app.jump(to: todo)
            } label: {
                Text(todo.title)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? Brand.Palette.secondary : Brand.Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .help("Go to this to-do")
            if let place = todo.project?.name ?? todo.area?.name {
                Text(place).foregroundStyle(Brand.Palette.secondary).lineLimit(1)
            }
            Menu(whenText(todo)) {
                Button("Today") { change("reschedule") { try $0.schedule(todo, .on(.now)) } }
                Button(Brand.Words.thisEvening) { change("reschedule") { try $0.schedule(todo, .on(.now, evening: true)) } }
                Button(Brand.Words.tomorrow) { change("reschedule") { try $0.schedule(todo, .on(SmartList.startOfTomorrow(now: .now, calendar: .current))) } }
                Button("Someday") { change("reschedule") { try $0.schedule(todo, .someday) } }
                Button("No Date") { change("reschedule") { try $0.schedule(todo, .unscheduled) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change when")
        }
        .font(Brand.Fonts.subtitle)
        .buttonStyle(.hand)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func whenText(_ todo: ToDo) -> String {
        if todo.isCompleted { return "Done" }
        if todo.when == .someday { return "Someday" }
        guard let day = todo.startDate else { return "No date" }
        if Calendar.current.isDateInToday(day) { return todo.evening ? "This evening" : "Today" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    private func change(_ what: String, _ edit: (Workspace) throws -> Void) {
        Alerts.shared.attempt(what) { try edit(Workspace(context: context, reminders: .shared)) }
    }
}
