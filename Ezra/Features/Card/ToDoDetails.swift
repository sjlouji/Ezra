import SwiftData
import SwiftUI

/// Everything an open to-do shows below its title: notes, checklist, tags, When and Deadline, bucket, and the tool icons.
struct ToDoDetails: View {
    @Bindable var todo: ToDo
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var addingTag = false
    @State private var newTag = ""
    @FocusState private var tagFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownEditor(text: $todo.notes, placeholder: Brand.Words.notes)
                .padding(.leading, 24)
            LinkedNoteChips(text: todo.notes).padding(.leading, 24)

            if !todo.sortedChecklist.isEmpty {
                VStack(spacing: 0) {
                    ForEach(todo.sortedChecklist) { item in
                        Rectangle().fill(Brand.Palette.hairline).frame(height: 1)
                        ChecklistLine(item: item) { remove(item) }
                            .padding(.vertical, 6)
                            .sortable(.checklist(item), in: .checklist(todo))
                    }
                }
                .padding(.leading, 24)
            }
            if !todo.tags.isEmpty || addingTag {
                tagRow.padding(.leading, 24)
            }
            if let rule = todo.repeatRule {
                RepeatEditor(rule: rule) { changed in
                    Alerts.shared.attempt("change the repeat") { try Workspace(context: context).setRepeat(todo, changed) }
                }
                .padding(.leading, 24)
            }
            if app.destination == .planner {
                BucketChips(selection: $todo.bucket).padding(.leading, 24)
            }
            HStack(alignment: .bottom, spacing: 14) {
                // Side by side when there is room, stacked when the column is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        whenChip
                        reminderChip
                        deadlineChip
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        whenChip
                        reminderChip
                        deadlineChip
                    }
                }
                .lineLimit(1)
                .padding(.leading, 24)
                Spacer(minLength: 8)
                toolButton("calendar", Brand.Words.when) { app.pick(.when, for: todo) }
                toolButton("tag", "Add tag") {
                    addingTag = true
                    tagFocused = true
                }
                toolButton("checklist", "Add checklist item", action: addChecklistItem)
                toolButton("flag", Brand.Words.deadline) { app.pick(.deadline, for: todo) }
                if todo.templateUUID == nil, !todo.isTemplate {
                    toolButton("arrow.triangle.2.circlepath", "Repeat") { startRepeating() }
                }
            }
            .padding(.top, 4)
        }
        .textFieldStyle(.plain)
        .foregroundStyle(Brand.Palette.ink)
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            ForEach(todo.tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                    Button("Remove tag \(tag)", systemImage: "xmark") { todo.tags.removeAll { $0 == tag } }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11))
                .foregroundStyle(Brand.Palette.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay { Capsule().strokeBorder(Brand.Palette.secondary.opacity(0.45), lineWidth: 1) }
            }
            if addingTag {
                TextField("Tag", text: $newTag)
                    .font(Brand.Fonts.subtitle)
                    .frame(width: 110)
                    .focused($tagFocused)
                    .onSubmit {
                        let tag = newTag.trimmed
                        if !tag.isEmpty, !todo.tags.contains(tag) { todo.tags.append(tag) }
                        (newTag, addingTag) = ("", false)
                    }
            }
        }
        .buttonStyle(.hand)
    }

    @ViewBuilder
    private var whenChip: some View {
        switch todo.when {
        case .dated:
            let isToday = SmartList.today.contains(todo) || (todo.startDate.map(Calendar.current.isDateInToday) ?? true)
            if isToday {
                chip(icon: todo.evening ? .moon : .star, todo.evening ? Brand.Words.thisEvening : SmartList.today.title) { clearWhen() }
            } else {
                chip(icon: .list(.upcoming), (todo.startDate ?? .now).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) { clearWhen() }
            }
        case .someday:
            chip(icon: .list(.someday), SmartList.someday.title) { clearWhen() }
        case .inbox, .anytime:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reminderChip: some View {
        if let reminder = todo.reminderAt {
            HStack(spacing: 5) {
                Image(systemName: "bell.fill").font(.system(size: 10))
                Text(reminder.formatted(.dateTime.hour().minute()))
                clearButton("Remove reminder") {
                    Alerts.shared.attempt("remove the reminder") { try Workspace(context: context).setReminder(todo, at: nil) }
                }
            }
            .font(Brand.Fonts.label)
            .foregroundStyle(Brand.Palette.secondary)
        }
    }

    /// Makes this to-do the pattern of a weekly repeat, and shows it in the Repeating list where its rule can be changed.
    private func startRepeating() {
        Alerts.shared.attempt("make the to-do repeat") {
            try Workspace(context: context).setRepeat(todo, RepeatRule())
            app.destination = .special(.repeating)
            app.open(todo)
        }
    }

    @ViewBuilder
    private var deadlineChip: some View {
        if let deadline = todo.deadline {
            HStack(spacing: 5) {
                Image(systemName: "flag.fill").font(.system(size: 10))
                Text("\(Brand.Words.deadline): \(deadline.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))").fixedSize()
                clearButton("Remove deadline") {
                    Alerts.shared.attempt("remove the deadline") { try Workspace(context: context).setDeadline(todo, nil) }
                }
            }
            .font(Brand.Fonts.label)
            .foregroundStyle(Brand.Palette.deadline)
        }
    }

    private func chip(icon: ListIcon.Kind, _ text: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            ListIcon(icon, size: 14)
            Text(text)
            clearButton("Clear \(Brand.Words.when)", action: clear)
        }
        .font(Brand.Fonts.label)
    }

    private func clearButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.hand)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Brand.Palette.secondary)
    }

    private func toolButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.hand)
            .font(.system(size: 13.5))
            .foregroundStyle(Brand.Palette.secondary.opacity(0.8))
            .help(label)
    }

    private func clearWhen() {
        Alerts.shared.attempt("clear the date") { try Workspace(context: context).schedule(todo, .unscheduled) }
    }

    private func addChecklistItem() {
        let item = ChecklistItem(title: "")
        context.insert(item)
        item.task = todo
    }

    private func remove(_ item: ChecklistItem) {
        context.delete(item)
    }
}

private struct ChecklistLine: View {
    @Bindable var item: ChecklistItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { item.isDone.toggle() }
            } label: {
                CheckBox(checked: item.isDone, circle: true, size: 13)
            }
            TextField("Item", text: $item.title)
                .font(.system(size: 13.5))
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? Brand.Palette.secondary : Brand.Palette.ink)
            Button("Remove item", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Brand.Palette.secondary.opacity(0.6))
        }
        .buttonStyle(.hand)
    }
}
