import SwiftUI

/// Prompts that run by themselves on a schedule.
struct AutomationsPane: View {
    let runner: AutomationRunner?
    @Bindable private var store = AutomationStore.shared
    @State private var editing: Automation?

    var body: some View {
        Form {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Brand.Palette.deadline)
            }
            Section {
                ForEach($store.items) { $automation in
                    HStack(spacing: 10) {
                        Toggle("On", isOn: $automation.enabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(automation.title.isEmpty ? "Untitled" : automation.title).fontWeight(.medium)
                            Text("\(automation.schedule). \(automation.lastRun.map { "Last ran \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "Has not run yet.")")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run Now") { Task { await runner?.run(automation) } }.disabled(runner == nil)
                        Button("Edit") { editing = automation }
                        Button("Delete", systemImage: "trash", role: .destructive) { store.items.removeAll { $0.id == automation.id } }
                            .labelStyle(.iconOnly)
                    }
                }
                Button("New Automation…") { editing = Automation(title: "Morning plan", prompt: "Plan my day: what is due, what is overdue, and what to do first.") }
            } footer: {
                PaneNote("An automation runs while \(Brand.name) is open, with the model chosen in the chat, and can add or change things as you could ask it to. Each run is saved as a chat in the Automations folder and announced with a notification. A run missed while \(Brand.name) was closed happens once when it opens. Automations stay on this Mac.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { automation in
            AutomationEditor(automation: automation) { saved in
                if let index = store.items.firstIndex(where: { $0.id == saved.id }) { store.items[index] = saved } else { store.items.append(saved) }
                editing = nil
            } cancel: {
                editing = nil
            }
        }
    }
}

private struct AutomationEditor: View {
    @State var automation: Automation
    let save: (Automation) -> Void
    let cancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $automation.title)
            TextField("What \(Brand.assistant) should do", text: $automation.prompt, axis: .vertical).lineLimit(3...6)
            Picker("Runs", selection: $automation.every) {
                ForEach(Automation.Every.allCases) { Text($0.title).tag($0) }
            }
            if automation.every == .week {
                Picker("On", selection: $automation.weekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
            }
            if automation.every == .month {
                Stepper("On day \(automation.day)", value: $automation.day, in: 1...28)
            }
            if automation.every != .hour {
                Stepper("At \(String(format: "%02d", automation.hour)):00 hours", value: $automation.hour, in: 0...23)
            }
            Stepper("Minute :\(String(format: "%02d", automation.minute))", value: $automation.minute, in: 0...55, step: 5)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(automation) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(automation.prompt.trimmed.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}

/// Every keyboard shortcut in one place.
struct ShortcutsPane: View {
    private let groups: [(String, [(String, String)])] = [
        ("Everywhere", [("⌃ Space", "Quick Entry, from any app"), ("⌘ N", "New to-do"), ("⌘ F", "Quick Find (or just start typing)"), ("⌘ J", "Go to \(Brand.assistant)"), ("⌘ [  ⌘ ]", "Back and forward"), ("⌘ /", "Hide or show the sidebar"), ("⌘ ,", "Settings")]),
        ("Trackpad", [("Swipe right on a to-do", "When"), ("Swipe left on a to-do", "Select it"), ("Swipe left on a checklist item", "Delete it"), ("Swipe left on the sidebar", "Hide it"), ("Swipe right from the left edge", "Show the sidebar"), ("Drag the sidebar's edge", "Hide or show it; double-click toggles"), ("Swipe right or left elsewhere", "Back and forward"), ("Pull a list down", "Quick Find"), ("Drag", "Reorder and move; drag the + to place a new to-do")]),
        ("An open to-do", [("⌘ S", "When"), ("⇧ ⌘ D", "Deadline"), ("⇧ ⌘ M", "Move"), ("⌘ T", "Today"), ("⌘ E", "This Evening"), ("⌘ R", "Anytime"), ("⌘ O", "Someday"), ("⌘ K", "Complete")]),
        ("Lists", [("⌘ click", "Pick several to-dos"), ("⇧ click", "Pick a range"), ("Esc", "Clear the selection or close a to-do")]),
        ("Chat", [("Return", "Send (waits its turn while a reply is being written)"), ("Tab", "Take the suggested continuation"), ("⌘ .", "Stop the reply"), ("⇧ ⌘ N", "New chat")]),
        ("Notes", [("⌘ B", "Bold"), ("⌘ I", "Italic")]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { title, shortcuts in
                Section(title) {
                    ForEach(shortcuts, id: \.0) { keys, meaning in
                        LabeledContent(meaning) {
                            Text(keys)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .padding(.vertical, 2)
                                .padding(.horizontal, 7)
                                .background(.quaternary, in: .rect(cornerRadius: 5))
                        }
                    }
                }
            }
            PaneNote("Shortcuts are fixed for now; they cannot be changed here.")
        }
        .formStyle(.grouped)
    }
}
