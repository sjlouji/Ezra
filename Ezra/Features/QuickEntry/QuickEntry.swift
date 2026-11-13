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
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 10), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
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
            let size = window.contentView?.fittingSize ?? CGSize(width: 600, height: 160)
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
    @State private var title: String
    @State private var notes: String
    @State private var when: String
    @State private var project: Project?
    @State private var problem: String?
    @FocusState private var titleFocused: Bool

    /// The texts are given only to draw the panel filled in, for its pictures.
    init(close: @escaping () -> Void, title: String = "", notes: String = "", when: String = "") {
        self.close = close
        (_title, _notes, _when) = (State(initialValue: title), State(initialValue: notes), State(initialValue: when))
    }

    var body: some View {
        let meaning = WhenPhrase.suggestions(for: when).first
        VStack(spacing: 0) {
            // What the to-do is.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    CheckBox(checked: false, size: 16)
                    TextField("", text: $title, prompt: Text(Brand.Words.newToDo).foregroundStyle(Brand.Palette.secondary))
                        .font(.system(size: 18, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit(save)
                }
                TextField("", text: $notes, prompt: Text(Brand.Words.notes).foregroundStyle(Brand.Palette.secondary.opacity(0.8)), axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.Palette.ink.opacity(0.8))
                    .lineLimit(1...6)
                    .padding(.leading, 28)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Rectangle().fill(Brand.Palette.hairline).frame(height: 1)

            // When, where, and saving it.
            HStack(spacing: 8) {
                whenChip(meaning)
                listChip
                DictationButton(text: $title)
                    .buttonStyle(.hand)
                    .foregroundStyle(Brand.Palette.secondary)
                    .frame(width: 26, height: 26)
                    .help("Say the to-do")
                Spacer(minLength: 8)
                // Esc closes the panel; the key needs no button of its own on screen.
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).hidden().frame(width: 0)
                Button(action: save) {
                    Text("Add To-Do")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Brand.Palette.accent.opacity(title.trimmed.isEmpty ? 0.4 : 1), in: .capsule)
                }
                .buttonStyle(.hand)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmed.isEmpty)
                .help("Add it (Return or ⌘Return)")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Brand.Palette.pageOpen)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Brand.Palette.deadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .background(Brand.Palette.pageOpen)
            }
        }
        .textFieldStyle(.plain)
        .foregroundStyle(Brand.Palette.ink)
        .frame(width: 600)
        .background(Brand.Palette.page)
        .onAppear { titleFocused = true }
        .onChange(of: when) { problem = nil }
    }

    /// The day, typed in words, with what it was understood as beside it.
    private func whenChip(_ meaning: WhenSuggestion?) -> some View {
        let unclear = meaning == nil && !when.trimmed.isEmpty
        return HStack(spacing: 6) {
            Image(systemName: meaning?.evening == true ? "moon.fill" : "calendar")
                .foregroundStyle(unclear ? Brand.Palette.deadline : meaning == nil ? Brand.Palette.secondary : Brand.Palette.accent)
            // As wide as what is typed, so the bar never runs out of room. A text field cannot be asked how wide its
            // text is, so a hidden copy of the text sets the width and the field fills it.
            ZStack(alignment: .leading) {
                Text(when.isEmpty ? "When" : when).hidden().padding(.trailing, 4)
                TextField("", text: $when, prompt: Text("When").foregroundStyle(Brand.Palette.secondary))
                    .onSubmit(save)
            }
            .fixedSize(horizontal: true, vertical: false)
            if meaning != nil || unclear {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.Palette.secondary)
            }
            if let meaning {
                Text(meaning.label)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Brand.Palette.accent)
            } else if unclear {
                Text("Not a date").fixedSize().foregroundStyle(Brand.Palette.deadline)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(unclear ? Brand.Palette.deadline.opacity(0.1) : Brand.Palette.field, in: .capsule)
        .help("Type when: today, tonight, tom, fri 2pm, in 3 days, someday")
        .animation(.easeOut(duration: 0.15), value: meaning?.label)
    }

    /// Where the to-do goes: the Inbox, or a project.
    private var listChip: some View {
        Menu {
            Button(SmartList.inbox.title, systemImage: "tray") { project = nil }
            let open = projects.filter { !$0.isCompleted && !$0.isTemplate }
            if !open.isEmpty { Divider() }
            ForEach(open) { candidate in
                Button(candidate.name) { project = candidate }
            }
        } label: {
            HStack(spacing: 6) {
                if let project {
                    ListIcon(.pie(progress: project.progress, tint: Brand.Palette.accent), size: 13)
                    Text(project.name).lineLimit(1)
                } else {
                    ListIcon(.list(.inbox), size: 14)
                    Text(SmartList.inbox.title)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.Palette.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: 190)
            .background(Brand.Palette.field, in: .capsule)
            .contentShape(.capsule)
        }
        // A plain button menu draws the label as given; the borderless style replaces it with its own.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where it goes")
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
