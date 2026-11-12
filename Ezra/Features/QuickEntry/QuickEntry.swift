import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

/// Quick Entry: press ⌃Space in any app and a small window takes a to-do without leaving what you were doing.
@MainActor
final class QuickEntry {
    static let shared = QuickEntry()
    /// False when macOS would not give the app the shortcut (another app or the system already has it).
    private(set) var isShortcutActive = false
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?

    /// Claims ⌃Space system-wide.
    func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { QuickEntry.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x455A_5241), id: 1) // "EZRA"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
        isShortcutActive = status == noErr
        if !isShortcutActive { Log.store.error("Quick Entry shortcut not registered: status \(status)") }
    }

    func toggle() {
        if panel != nil { return close() }
        guard let container = EzraStore.shared else { return }
        let window = KeyPanel(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 10), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.contentView = NSHostingView(rootView: QuickEntryView { [weak self] in self?.close() }.modelContainer(container))
        if let screen = NSScreen.main {
            let size = window.contentView?.fittingSize ?? CGSize(width: 520, height: 200)
            window.setFrame(CGRect(
                x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - screen.visibleFrame.height * 0.28 - size.height,
                width: size.width, height: size.height
            ), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        panel = window
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// A panel that can take typing without bringing the whole app forward.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickEntryView: View {
    let close: () -> Void
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.order) private var projects: [Project]
    @State private var title = ""
    @State private var notes = ""
    @State private var when = ""
    @State private var project: Project?
    @State private var problem: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        let meaning = WhenPhrase.suggestions(for: when).first
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CheckBox(checked: false).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                TextField(Brand.Words.newToDo, text: $title)
                    .font(.system(size: 15, weight: .medium))
                    .focused($titleFocused)
                    .onSubmit(save)
                DictationButton(text: $title).buttonStyle(.hand)
            }
            TextField(Brand.Words.notes, text: $notes, axis: .vertical)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .padding(.leading, 24)
            HStack(spacing: 10) {
                Image(systemName: "calendar").foregroundStyle(Brand.Palette.secondary)
                TextField("When: tom, fri 2pm, in 3 days", text: $when)
                    .frame(width: 190)
                    .onSubmit(save)
                if let meaning {
                    Text(meaning.label).foregroundStyle(Brand.Palette.accent)
                } else if !when.trimmed.isEmpty {
                    Text("not a date").foregroundStyle(Brand.Palette.deadline)
                }
                Spacer()
                Picker("List", selection: $project) {
                    Text(SmartList.inbox.title).tag(Project?.none)
                    ForEach(projects.filter { !$0.isCompleted && !$0.isTemplate }) { project in
                        Text(project.name).tag(Project?.some(project))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(.system(size: 12.5))
            .padding(.leading, 24)
            HStack {
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Brand.Palette.deadline)
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(Brand.Words.save, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmed.isEmpty)
            }
            .controlSize(.small)
        }
        .textFieldStyle(.plain)
        .foregroundStyle(Brand.Palette.ink)
        .padding(18)
        .frame(width: 520)
        .background(Brand.Palette.page)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard !title.trimmed.isEmpty else { return }
        do {
            let workspace = Workspace(context: context)
            var schedule = project == nil ? Schedule.unscheduled : .anytime
            var reminder: Date?
            if !when.trimmed.isEmpty {
                guard let meaning = WhenPhrase.suggestions(for: when).first else { throw WorkspaceError.badDate(when) }
                schedule = meaning.date.map { .on($0, evening: meaning.evening) } ?? .someday
                reminder = meaning.reminderDate
            }
            try workspace.addToDo(title: title, notes: notes, project: project, schedule: schedule, reminderAt: reminder)
            close()
        } catch {
            Log.store.error("Quick Entry could not save: \(String(describing: error), privacy: .public)")
            problem = error.localizedDescription
        }
    }
}
