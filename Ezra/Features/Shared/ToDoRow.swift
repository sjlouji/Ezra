import SwiftData
import SwiftUI

/// The run of rows a to-do row belongs to, so a drag can reorder within it.
struct RunRef {
    let id: UUID
    /// Where a to-do dragged in from another run lands when dropped on this row.
    let fallback: DropTarget?
}

/// A to-do in a list. Click and it grows into its card where it sits: the checkbox and title
/// stay put, the card forms around them and the details fade in below.
struct ToDoRow: View {
    enum Style {
        case standard
        /// A completed row with the day it was done.
        case logbook
        /// Leads with the day it is planned for.
        case dated
    }

    let todo: ToDo
    var style = Style.standard
    var showsContainer = true
    /// Lead with when it is planned: a star or moon for today, a date chip for later. For lists that are not about one day.
    var showsWhen = false
    var run: RunRef?
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    /// Checked a moment ago and about to slide away to the Logbook.
    @State private var leaving: Task<Void, Never>?
    @State private var slotID = UUID()
    @State private var probe: ProbeView?
    @FocusState private var titleFocused: Bool

    private var openCard: AppModel.OpenCard? { app.card.flatMap { $0.todo == todo ? $0 : nil } }

    var body: some View {
        let isOpen = openCard != nil
        // Registered on every pass, so the slot always names the run and fallback this row has now.
        let _ = register()
        VStack(alignment: .leading, spacing: 10) {
            header(isOpen: isOpen)
            if isOpen {
                ToDoDetails(todo: todo)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                        removal: .opacity.animation(.easeOut(duration: 0.07))
                    ))
            }
        }
        .padding(.vertical, isOpen ? 14 : 4.5)
        .background {
            // The card reaches past the text on both sides, so the text itself never moves.
            RoundedRectangle(cornerRadius: isOpen ? 10 : 7, style: .continuous)
                .fill(isOpen ? Brand.Palette.page : app.isSelected(todo) ? Brand.Palette.accent.opacity(0.14) : Brand.Palette.page.opacity(0))
                .shadow(color: .black.opacity(isOpen ? 0.1 : 0), radius: isOpen ? 7 : 0, y: isOpen ? 2 : 0)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Brand.Palette.hairline.opacity(isOpen ? 1 : 0), lineWidth: 1)
                }
                .padding(.horizontal, -14)
        }
        .padding(.vertical, isOpen ? 16 : 0)
        .zIndex(isOpen ? 1 : 0)
        .contentShape(.rect)
        .opacity(app.drag?.item == .todo(todo) ? 0 : 1) // the gap a dragged to-do leaves
        .offset(x: app.swipeOffset(for: todo))
        .background { SwipeHint(todo: todo) }
        .onTapGesture { clicked(isOpen: isOpen) }
        .pointerStyle(isOpen ? .default : .link)
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { _ in
                    guard !isOpen, !todo.isCompleted, let pointer = AppModel.pointer(), let origin = probe?.windowFrame() else { return }
                    app.dragChanged(.todo(todo), at: pointer, from: origin)
                }
                .onEnded { _ in app.dragEnded() }
        )
        .background { Probe { probe = $0 } }
        .onDisappear { app.slots[slotID] = nil }
        .onExitCommand { app.closeCard() }
        .contextMenu {
            if !todo.isCompleted {
                Button("\(Brand.Words.when)…") { app.pick(.when, for: todo) }
                Button("\(Brand.Words.deadline)…") { app.pick(.deadline, for: todo) }
            }
            Button("Delete", role: .destructive) {
                Alerts.shared.attempt("delete the to-do") { try Workspace(context: context).delete(todo) }
            }
        }
    }

    private func header(isOpen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: toggle) {
                CheckBox(checked: todo.isCompleted || leaving != nil)
            }
            .buttonStyle(.hand)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }

            if !isOpen, let label = leadingLabel {
                Text(label)
                    .font(Brand.Fonts.label)
                    .foregroundStyle(Brand.Palette.accent)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if !isOpen, showsWhen { whenMarker }
                    title(isOpen: isOpen)
                    if !isOpen { indicators.transition(.opacity) }
                }
                if !isOpen, showsContainer, let container = todo.containerName {
                    Text(container)
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.secondary)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 12)
            if !isOpen, style != .logbook { deadlineLabel.transition(.opacity) }
        }
    }

    /// A star or moon for a to-do that is in Today, a grey date chip for one planned later.
    @ViewBuilder
    private var whenMarker: some View {
        if SmartList.today.contains(todo), todo.when == .dated {
            ListIcon(todo.evening ? .moon : .star, size: 13)
        } else if todo.when == .dated, let start = todo.startDate {
            Text(start.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.Palette.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Brand.Palette.field, in: .rect(cornerRadius: 4))
        }
    }

    /// One Text lays the title out in both states, so nothing shifts on opening. The editor always sits
    /// exactly on top of it, invisible and inert until the to-do is open, so the two move as one.
    private func title(isOpen: Bool) -> some View {
        Text(todo.title.isEmpty ? Brand.Words.newToDo : todo.title)
            .font(Brand.Fonts.row)
            .foregroundStyle(leaving == nil && !todo.title.isEmpty ? Brand.Palette.ink : Brand.Palette.secondary)
            .lineLimit(isOpen ? nil : 2)
            .frame(maxWidth: isOpen ? .infinity : nil, alignment: .leading)
            .modifier(StepOpacity(progress: isOpen ? 1 : 0, visibleWhenOpen: false))
            .overlay(alignment: .topLeading) {
                TextField(Brand.Words.newToDo, text: Bindable(todo).title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Brand.Fonts.row)
                    .foregroundStyle(Brand.Palette.ink)
                    .focused($titleFocused)
                    .onSubmit { app.closeCard() }
                    .modifier(StepOpacity(progress: isOpen ? 1 : 0, visibleWhenOpen: true))
                    .disabled(!isOpen)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)
            }
            .onChange(of: openCard?.isNew == true, initial: true) { _, isNew in
                if isNew { titleFocused = true }
            }
    }

    /// Small grey marks after the title: has notes, has a checklist, has a reminder; then its tags as outlined pills.
    private var indicators: some View {
        HStack(spacing: 6) {
            Group {
                if !todo.notes.isEmpty { Image(systemName: "doc").accessibilityLabel("Has notes") }
                if !(todo.checklist ?? []).isEmpty { Image(systemName: "checklist").accessibilityLabel("Has a checklist") }
                if !todo.noteIDs.isEmpty { Image(systemName: "doc.text").accessibilityLabel("Has \(todo.noteIDs.count) notes attached") }
                if todo.templateUUID != nil || todo.isTemplate { Image(systemName: "arrow.triangle.2.circlepath").accessibilityLabel("Repeats") }
            }
            .font(.system(size: 11))
            if let reminder = todo.reminderAt {
                Label(reminder.formatted(.dateTime.hour().minute()), systemImage: "bell")
                    .font(.system(size: 11.5))
                    .labelStyle(.titleAndIcon)
            }
            if let rule = todo.repeatRule {
                Text(rule.summary).font(.system(size: 11.5))
            }
            ForEach(todo.tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay { Capsule().strokeBorder(Brand.Palette.secondary.opacity(0.45), lineWidth: 1) }
            }
        }
        .foregroundStyle(Brand.Palette.secondary.opacity(0.85))
        .lineLimit(1)
        .fixedSize()
    }

    private var leadingLabel: String? {
        switch style {
        case .logbook:
            guard let done = todo.completedAt else { return nil }
            return Calendar.current.isDateInToday(done) ? "today" : done.formatted(.dateTime.month(.defaultDigits).day())
        case .dated:
            return todo.startDate?.formatted(.dateTime.month(.abbreviated).day())
        case .standard:
            return nil
        }
    }

    @ViewBuilder
    private var deadlineLabel: some View {
        if let days = todo.daysToDeadline() {
            let urgent = days <= 0
            HStack(spacing: 3) {
                Image(systemName: "flag.fill").font(.system(size: 11))
                Text(days == 0 ? "today" : days < 0 ? "\(-days)d ago" : "\(days)d left")
            }
            .font(Brand.Fonts.label)
            .foregroundStyle(urgent ? Brand.Palette.deadline : Brand.Palette.secondary)
        }
    }

    private func register() {
        guard let run, let probe else { return }
        app.slots[slotID] = RowSlot(probe: probe, todo: todo, runID: run.id, fallback: run.fallback)
    }

    /// A click opens the to-do in place. A click inside an open one stays inside it.
    /// A plain click opens the to-do; with ⌘ or ⇧ held it picks it for a change to several at once.
    private func clicked(isOpen: Bool) {
        guard !isOpen else { return }
        let keys = NSEvent.modifierFlags
        if keys.contains(.command), !todo.isCompleted { return app.toggleSelection(todo) }
        if keys.contains(.shift), !todo.isCompleted { return app.extendSelection(to: todo, in: run.flatMap { app.runs[$0.id] } ?? [todo]) }
        app.clearSelection()
        if todo.isCompleted { app.closeCard() } else { app.open(todo) }
    }

    /// Checking keeps the row for a second (a second click takes it back), then logs it. Unchecking is immediate.
    private func toggle() {
        if let pending = leaving {
            pending.cancel()
            leaving = nil
            return
        }
        if todo.isCompleted {
            withAnimation(AppModel.spring) {
                Alerts.shared.attempt("reopen the to-do") { try Workspace(context: context).setCompleted(todo, false) }
            }
            return
        }
        leaving = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            if openCard != nil { app.closeCard() }
            withAnimation(AppModel.spring) {
                Alerts.shared.attempt("complete the to-do") { try Workspace(context: context).setCompleted(todo, true) }
                leaving = nil
            }
        }
    }
}

/// What tells one row from every other: the to-do it shows and the run it is in.
private struct RowID: Hashable {
    let run: UUID
    let todo: PersistentIdentifier
}

/// A run of to-do rows on a screen. Dragging one past another moves it there at once, so the rest part to make room.
struct ToDoRows: View {
    let todos: [ToDo]
    var style = ToDoRow.Style.standard
    var showsContainer = true
    var showsWhen = false
    /// What a to-do dragged in from another run of rows becomes when dropped on one of these: this section's day, project or heading.
    var section: DropTarget?
    @Environment(AppModel.self) private var app
    @State private var runID = UUID()
    /// How many rows are loaded so far. A long list starts with one page and takes the next as its end scrolls into view.
    @State private var loaded = ToDoRows.page
    static let page = 100

    var body: some View {
        let _ = app.runs[runID] = todos
        // A row is known by its to-do and this run together. Known by the to-do alone, a row that moves to another
        // section of the same screen is carried over as it was, still naming the section it left.
        ForEach(todos.prefix(loaded), id: \.persistentModelID) { todo in
            ToDoRow(todo: todo, style: style, showsContainer: showsContainer, showsWhen: showsWhen, run: RunRef(id: runID, fallback: section))
                .plainRow()
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .id(RowID(run: runID, todo: todo.persistentModelID))
        }
        if todos.count > loaded {
            Text("Showing \(loaded.formatted()) of \(todos.count.formatted())")
                .font(Brand.Fonts.subtitle)
                .foregroundStyle(Brand.Palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .plainRow()
                // This row exists only once the list has been scrolled to its end, which is the moment to load the next page.
                .onAppear { loaded += Self.page }
        }
    }
}
