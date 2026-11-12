import EventKit
import SwiftUI
import UserNotifications

/// Which model answers, the Ollama model, and the user's Claude API key. The key is typed here and kept in the Keychain.
struct AssistantPane: View {
    @Bindable var chat: ChatModel
    @State private var claudeKey = ""
    @AppStorage(ChatModel.accountInstructionsKey) private var instructions = ""
    @AppStorage(PromptPredictor.key) private var autocompletes = true

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $chat.engine) {
                    ForEach(AssistantEngine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(chat.isResponding)
                PaneNote("On this Mac is Apple's model: free and private, for short requests about your to-dos. Ollama runs a larger model on this Mac: also free and private, better with files, ideas and charts, no web. Claude answers anything and searches the web.")
            }
            Section("In every chat") {
                TextField("Standing instructions, for example: keep answers short; I work Monday to Thursday", text: $instructions, axis: .vertical)
                    .lineLimit(2...4)
                    .labelsHidden()
                Toggle("Suggest how my message continues as I type", isOn: $autocompletes)
                PaneNote("Instructions here apply to every chat; a chat's own instructions (the slider button in the chat) are added to them. Suggestions come from Apple's model on this Mac; press Tab to take one.")
            }
            Section("Ollama") {
                HStack {
                    Picker("Model", selection: $chat.ollamaModel) {
                        if chat.ollamaModels.isEmpty { Text("None found").tag(String?.none) }
                        ForEach(chat.ollamaModels, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .disabled(chat.ollamaModels.isEmpty || chat.isResponding)
                    Button("Refresh") { Task { await chat.refreshOllama() } }
                        .help("Ask Ollama again which models are installed")
                }
                if let problem = chat.ollamaProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Brand.Palette.deadline).textSelection(.enabled)
                }
            }
            Section("Claude") {
                if chat.hasClaudeKey {
                    HStack {
                        Label("API key saved", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.Palette.logbook)
                        Spacer()
                        Button("Remove Key", role: .destructive) {
                            Alerts.shared.attempt("remove the Claude key") { try chat.setClaudeKey(nil) }
                        }
                    }
                } else {
                    SecureField("API key", text: $claudeKey, prompt: Text("from console.anthropic.com")).onSubmit(saveClaudeKey)
                    Button("Save Key", action: saveClaudeKey).disabled(claudeKey.trimmed.isEmpty)
                }
                PaneNote("Claude uses your own Anthropic API key and is paid per use. What you write, the files you attach and the to-dos it reads are sent to Anthropic.")
            }
        }
        .formStyle(.grouped)
        .task { await chat.refreshOllama() }
    }

    private func saveClaudeKey() {
        guard !claudeKey.trimmed.isEmpty else { return }
        Alerts.shared.attempt("save the Claude key") {
            try chat.setClaudeKey(claudeKey)
            claudeKey = ""
            chat.engine = .claude
        }
    }
}

struct QuickEntryPane: View {
    var body: some View {
        let active = QuickEntry.shared.isShortcutActive
        Form {
            LabeledContent("Shortcut") {
                Text("⌃ Space")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(.quaternary, in: .rect(cornerRadius: 5))
            }
            LabeledContent("Status") {
                Label(active ? "Ready" : "Unavailable", systemImage: active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(active ? Brand.Palette.logbook : Brand.Palette.deadline)
            }
            PaneNote(active
                ? "Press the shortcut in any app to add a to-do without leaving it. Type a date or time after the title, such as “tomorrow” or “fri 9am”."
                : "macOS did not give \(Brand.name) this shortcut. It is usually taken by “Select the previous input source” in System Settings › Keyboard › Keyboard Shortcuts › Input Sources. Turn that off, then reopen \(Brand.name).")
        }
        .formStyle(.grouped)
    }
}

/// Whether macOS lets the app show reminders, with the way to change it.
struct RemindersPane: View {
    @State private var status: UNAuthorizationStatus?
    @AppStorage(ReminderScheduler.briefingKey) private var morningBriefing = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let allowed = status == .authorized || status == .provisional
        Form {
            LabeledContent("Notifications") {
                switch status {
                case nil: ProgressView().controlSize(.small)
                case .notDetermined?: Text("Not asked yet").foregroundStyle(.secondary)
                default:
                    Label(allowed ? "Allowed" : "Blocked", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(allowed ? Brand.Palette.logbook : Brand.Palette.deadline)
                }
            }
            Toggle("Morning briefing at 8:00", isOn: $morningBriefing)
                .onChange(of: morningBriefing) { ReminderScheduler.shared.setMorningBriefing(morningBriefing) }
            Button("Open Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.ezra.Ezra") { openURL(url) }
            }
            PaneNote(status == .notDetermined
                ? "macOS asks for permission the first time you set a reminder."
                : allowed
                    ? "A reminder appears at its time with buttons to snooze it for 15 minutes, 1 hour, 3 hours or a day. Set one by typing a time in the When box, or ask \(Brand.assistant)."
                    : "Reminders are saved but macOS will not show them. Turn on “Allow notifications” for \(Brand.name), then set the reminder again.")
        }
        .formStyle(.grouped)
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}

/// Apple Calendar: whether events show beside to-dos, and from which calendars.
struct CalendarPane: View {
    @AppStorage("showCalendarEvents") private var showsEvents = true

    var body: some View {
        let service = CalendarService.shared
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show Calendar Events in Today and Upcoming lists", isOn: $showsEvents)
                .toggleStyle(.checkbox)
            if service.isConnected {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(service.calendars.enumerated()), id: \.element.calendarIdentifier) { index, calendar in
                            Toggle(isOn: Binding(get: { service.isShown(calendar) }, set: { service.setShown(calendar, $0) })) {
                                Text(calendar.title).padding(.leading, 6)
                            }
                            .toggleStyle(.checkbox)
                            .tint(Color(cgColor: calendar.cgColor))
                            .padding(.vertical, 7)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                        }
                    }
                }
                .frame(height: 230)
                .background(.background)
                .border(.quaternary)
                .disabled(!showsEvents)
                HStack {
                    PaneNote("Events are read from the Calendar app on this Mac and are not synced by \(Brand.name).")
                    Spacer()
                    Button("Disconnect") { service.disconnect() }
                }
            } else {
                PaneNote("Connect Apple Calendar to see your events beside your to-dos. Google and other accounts appear once they are added to the Calendar app.")
                Button("Connect Apple Calendar") { Task { await service.connect() } }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
