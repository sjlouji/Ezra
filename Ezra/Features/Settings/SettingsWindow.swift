import SwiftData
import SwiftUI

/// The Settings window: one tab per subject, as Mac apps do it.
struct SettingsWindow: View {
    let chat: ChatModel
    let sync: SyncEngine?
    var automations: AutomationRunner?
    @AppStorage(Brand.Appearance.key) private var appearance = Brand.Appearance.automatic.rawValue

    var body: some View {
        TabView {
            Tab("General", systemImage: "slider.horizontal.3") { GeneralPane() }
            Tab("Sync", systemImage: "checkmark.icloud") { SyncPane(sync: sync) }
            Tab(Brand.assistant, systemImage: "sparkles") { AssistantPane(chat: chat) }
            Tab("Claude", systemImage: "link") { ClaudePane() }
            Tab("Automations", systemImage: "clock.arrow.2.circlepath") { AutomationsPane(runner: automations) }
            Tab("Quick Entry", systemImage: "plus.app") { QuickEntryPane() }
            Tab("Reminders", systemImage: "list.bullet.rectangle") { RemindersPane() }
            Tab("Calendar", systemImage: "calendar") { CalendarPane() }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsPane() }
        }
        .scenePadding()
        .frame(width: 720)
        .preferredColorScheme(Brand.Appearance(rawValue: appearance)?.scheme)
        .font(.system(size: 14))
    }
}

/// A pane's small grey explanation.
struct PaneNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The icon, where attached files live, the totals and the demo data.
struct GeneralPane: View {
    @Environment(\.modelContext) private var context
    @Query private var todos: [ToDo]
    @Query private var projects: [Project]
    @AppStorage(DockIcon.sceneKey) private var scene = DockIcon.Scene.automatic.rawValue
    @AppStorage(Brand.Appearance.key) private var appearance = Brand.Appearance.automatic.rawValue
    @AppStorage("menubar.shown") private var showsMenuBarItem = true
    @State private var confirmsRemove = false
    @State private var isChoosingFolder = false

    var body: some View {
        let open = todos.filter { !$0.isCompleted }
        let folder = AttachmentStore.shared.chosenFolder
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Brand.Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Show today's count in the menu bar", isOn: $showsMenuBarItem)
            }
            Section("Icon") {
                HStack(spacing: 14) {
                    ForEach(["Icon-light-day", "Icon-light-night", "Icon-dark-day", "Icon-dark-night"], id: \.self) { name in
                        Image(name).resizable().frame(width: 56, height: 56)
                    }
                }
                Picker("Scene", selection: $scene) {
                    ForEach(DockIcon.Scene.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: scene) { DockIcon.apply() }
                PaneNote("The Dock icon uses the light or dark tile to match your Mac, and the day scene from 6 am to 6 pm. macOS shows the light day icon in Finder and whenever \(Brand.name) is closed.")
            }
            Section("Attached Files") {
                PaneNote(folder.map { "Files attached to notes are kept in \($0.path(percentEncoded: false)). iCloud carries them to your other devices." }
                    ?? "Files attached to notes are kept inside \(Brand.name) on this Mac only. Choose a folder in iCloud Drive and they will reach your other devices too.")
                Button(folder == nil ? "Choose Folder…" : "Change Folder…") { isChoosingFolder = true }
            }
            Section("Your Data") {
                LabeledContent("Open to-dos", value: "\(open.count)")
                LabeledContent("Completed to-dos", value: "\(todos.count - open.count)")
                LabeledContent("Due today or overdue", value: "\(open.count { ($0.daysToDeadline() ?? 1) <= 0 })")
                LabeledContent("Active projects", value: "\(projects.count { !$0.isCompleted && !$0.isTemplate })")
            }
            Section("Demo Data") {
                HStack {
                    Button("Reset Demo Data") {
                        Alerts.shared.attempt("reset the demo data") { try Seeder.reset(context: context) }
                    }
                    Button("Remove Demo Data…", role: .destructive) { confirmsRemove = true }
                        .disabled(!todos.contains(where: \.isDemo) && !projects.contains(where: \.isDemo))
                }
                PaneNote("Demo items are the sample areas, projects and to-dos. Your own items are never touched by either button.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            Alerts.shared.attempt("use that folder") { try AttachmentStore.shared.choose(try result.get()) }
        }
        .confirmationDialog("Remove the sample areas, projects and to-dos?", isPresented: $confirmsRemove) {
            Button("Remove Demo Data", role: .destructive) {
                Alerts.shared.attempt("remove the demo data") { try Seeder.removeDemo(context: context) }
            }
        }
    }
}

/// The account that keeps every device in step: a badge on the left, the account on the right.
struct SyncPane: View {
    let sync: SyncEngine?
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(spacing: 10) {
                Image(systemName: sync?.isSignedIn == true ? "checkmark.icloud.fill" : "icloud.slash")
                    .font(.system(size: 84))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(sync?.isSignedIn == true ? Brand.Palette.accent : Color.secondary)
                (Text(Brand.name).bold() + Text(" Sync")).font(.system(size: 25))
                Label(sync?.isSignedIn == true ? "On" : "Off", systemImage: "circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(sync?.isSignedIn == true ? Brand.Palette.logbook : Color.secondary)
            }
            .frame(width: 200)
            VStack(alignment: .leading, spacing: 10) {
                if let sync, sync.status != .unavailable {
                    account(sync)
                } else {
                    PaneNote(SyncError.notConfigured.localizedDescription)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func account(_ sync: SyncEngine) -> some View {
        Text("Your Account:").bold()
        if sync.isSignedIn {
            Text(sync.email ?? "")
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
                .textSelection(.enabled)
            HStack {
                Button("Sync Now") { Task { await sync.syncNow() } }
                Button("Sign Out", role: .destructive) { sync.signOut() }
            }
            PaneNote("Your account is active. To-dos, projects, notes, events and chats are kept in step across your devices.")
        } else {
            TextField("Email", text: $email).textContentType(.username)
            SecureField("Password", text: $password).onSubmit { signIn(sync) }
            Button("Sign In") { signIn(sync) }
                .disabled(email.trimmed.isEmpty || password.isEmpty)
            PaneNote("Sign in with the account you created in your Firebase project.")
        }
        switch sync.status {
        case .idle(let lastSync?):
            PaneNote("Last Updated: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Brand.Palette.deadline).textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    private func signIn(_ sync: SyncEngine) {
        let (address, secret) = (email, password)
        password = ""
        Task { await sync.signIn(email: address, password: secret) }
    }
}
