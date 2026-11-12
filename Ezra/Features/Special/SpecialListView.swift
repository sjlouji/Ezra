import SwiftData
import SwiftUI

/// The lists reached by name through Quick Find: Tomorrow, Deadlines, Repeating, All Projects, All Notes, Logged Projects.
struct SpecialListView: View {
    let kind: SpecialList
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(Library.self) private var library
    private var todos: [ToDo] { library.open }
    @Query(sort: \Project.order) private var projects: [Project]
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]

    var body: some View {
        ScreenList {
            ScreenTitle(icon: icon, title: kind.rawValue).plainRow()
            switch kind {
            case .tomorrow:
                let tomorrow = SmartList.day(1)
                rows(todos.filter { !$0.isCompleted && !$0.isTemplate && $0.when == .dated && $0.startDate == tomorrow }, empty: "Nothing planned for tomorrow")
            case .deadlines:
                rows(
                    todos.filter { !$0.isCompleted && !$0.isTemplate && $0.deadline != nil }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) },
                    empty: "No to-dos have a deadline"
                )
            case .repeating:
                let templates = todos.filter(\.isTemplate)
                let repeatingProjects = projects.filter { $0.repeatRule != nil }
                if templates.isEmpty && repeatingProjects.isEmpty {
                    EmptyRow(text: "Nothing repeats yet. Open a to-do and click the repeat icon.").plainRow()
                }
                ToDoRows(todos: templates)
                projectRows(repeatingProjects)
            case .templates:
                let blueprints = projects.filter(\.isBlueprint)
                if blueprints.isEmpty {
                    EmptyRow(text: "No templates yet. Open a project and choose Save as Template from its ··· menu.").plainRow()
                }
                projectRows(blueprints)
            case .allProjects:
                projectRows(projects.filter { !$0.isCompleted && !$0.isTemplate })
            case .loggedProjects:
                projectRows(projects.filter(\.isCompleted))
            case .allNotes:
                // Every note wherever it is filed, the most recently edited first.
                if notes.isEmpty { EmptyRow(text: "No notes yet. Use New Note in the toolbar of any list.").plainRow() }
                NoteRows(notes: notes, showsContainer: true)
            }
        }
    }

    private var icon: ListIcon.Kind {
        switch kind {
        case .tomorrow: .list(.upcoming)
        case .deadlines: .list(.upcoming)
        case .repeating, .templates: .list(.anytime)
        case .allProjects, .loggedProjects: .pie(progress: 0.5, tint: Brand.Palette.accent)
        case .allNotes: .list(.inbox)
        }
    }

    @ViewBuilder
    private func rows(_ shown: [ToDo], empty: String) -> some View {
        if shown.isEmpty { EmptyRow(text: empty).plainRow() }
        ToDoRows(todos: shown)
    }

    private func projectRows(_ shown: [Project]) -> some View {
        ForEach(shown) { project in
            HStack(spacing: 10) {
                ListIcon(.pie(progress: project.progress, tint: Brand.Palette.secondary), size: 15)
                Text(project.name).font(Brand.Fonts.rowBold)
                if let rule = project.repeatRule {
                    Label(rule.summary, systemImage: "arrow.triangle.2.circlepath")
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.secondary)
                }
                Spacer()
                if project.isBlueprint {
                    Button("New Project from This") {
                        Alerts.shared.attempt("create the project") {
                            app.destination = .project(try Workspace(context: context).stampOut(project))
                        }
                    }
                    .buttonStyle(.hand)
                    .font(Brand.Fonts.label)
                    .foregroundStyle(Brand.Palette.accent)
                }
                Text(project.area?.name ?? "").font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
            .onTapGesture { app.destination = .project(project) }
            .pointerStyle(.link)
            .accessibilityAddTraits(.isButton)
            .plainRow()
        }
    }
}

/// The rule of a repeating to-do or project: how often, and pause or stop.
struct RepeatEditor: View {
    let rule: RepeatRule
    let change: (RepeatRule?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Brand.Palette.accent)
                Picker("Repeat", selection: Binding(get: { rule.mode }, set: { updated(\.mode, $0) })) {
                    Text("On a schedule").tag(RepeatRule.Mode.schedule)
                    Text("After completion").tag(RepeatRule.Mode.afterCompletion)
                }
                .fixedSize()
                Stepper("every \(rule.every)", value: Binding(get: { rule.every }, set: { updated(\.every, $0) }), in: 1...99)
                    .fixedSize()
                Picker("Unit", selection: Binding(get: { rule.unit }, set: { updated(\.unit, $0) })) {
                    ForEach(RepeatRule.Unit.allCases, id: \.self) { unit in
                        Text(rule.every == 1 ? unit.rawValue : "\(unit.rawValue)s").tag(unit)
                    }
                }
                .fixedSize()
            }
            .labelsHidden()
            if rule.mode == .schedule {
                HStack(spacing: 5) {
                    if rule.unit == .week {
                        // The days of the week it falls on; none chosen means the day it started.
                        ForEach(1...7, id: \.self) { weekday in
                            let isOn = rule.weekdays?.contains(weekday) ?? false
                            Button(Calendar.current.veryShortWeekdaySymbols[weekday - 1]) {
                                let days = Set(rule.weekdays ?? []).symmetricDifference([weekday])
                                updated(\.weekdays, days.isEmpty ? nil : days.sorted())
                            }
                            .buttonStyle(.hand)
                            .font(Brand.Fonts.label)
                            .foregroundStyle(isOn ? .white : Brand.Palette.ink)
                            .frame(width: 22, height: 22)
                            .background(isOn ? Brand.Palette.accent : Brand.Palette.page, in: .circle)
                            .help(Calendar.current.weekdaySymbols[weekday - 1])
                        }
                        Spacer().frame(width: 8)
                    }
                    Picker("Deadline", selection: Binding(get: { rule.deadlineAfter }, set: { updated(\.deadlineAfter, $0) })) {
                        Text("No deadline").tag(Int?.none)
                        Text("Due that day").tag(Int?.some(0))
                        ForEach([1, 2, 3, 7], id: \.self) { Text("Due \($0) day\($0 == 1 ? "" : "s") later").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HStack(spacing: 12) {
                Text(rule.next.map { "\(rule.summary). Next: \($0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))" } ?? rule.summary)
                    .foregroundStyle(Brand.Palette.secondary)
                Spacer()
                Button(rule.isPaused ? "Resume" : "Pause") { updated(\.isPaused, !rule.isPaused) }
                Button("Stop Repeating", role: .destructive) { change(nil) }
            }
        }
        .font(Brand.Fonts.subtitle)
        .controlSize(.small)
        .padding(10)
        .background(Brand.Palette.field.opacity(0.7), in: .rect(cornerRadius: 8))
    }

    private func updated<Value>(_ field: WritableKeyPath<RepeatRule, Value>, _ value: Value) {
        var changed = rule
        changed[keyPath: field] = value
        change(changed)
    }
}
