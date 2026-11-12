import AppKit
import SwiftUI

/// Lets Claude Code and the Claude desktop app use Ezra: the switch, and what to give each of them.
struct ClaudePane: View {
    @AppStorage(MCPServer.enabledKey) private var enabled = false
    @State private var copied: String?
    @State private var confirmsReset = false
    @State private var isChoosingConfig = false
    @State private var addedToDesktop = false
    private let server = MCPServer.shared

    /// The helper Claude starts, inside this copy of the app.
    private var helper: String { Bundle.main.bundleURL.appending(path: "Contents/MacOS/ezra-mcp").path }
    private var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    var body: some View {
        Form {
            Section("Claude") {
                Toggle("Let Claude use Ezra", isOn: $enabled)
                    .onChange(of: enabled) { server.apply() }
                LabeledContent("Status") { status }
                PaneNote("When this is on, Claude Code and the Claude desktop app on this Mac can read your to-dos, projects, notes and calendar, and add or change them. Nothing leaves this Mac through Ezra, and a web page cannot reach it. Ezra has to be running; Claude opens it when needed.")
            }
            Section("Set up Claude Code") {
                Button("Copy the Command") { copy(as: "code") { try codeCommand } }
                PaneNote(copied == "code" ? "Copied. Paste it into Terminal and press Return, then start a new Claude Code session." : "Paste it into Terminal once. It adds Ezra to Claude Code for every project.")
            }
            Section("Set up the Claude desktop app") {
                Button("Add Ezra to the Claude Desktop App…") { isChoosingConfig = true }
                PaneNote(addedToDesktop
                    ? "Added. Open Claude; Ezra's tools are then there."
                    : "Quit Claude first (⌘Q): it writes its settings back when it quits, which would remove Ezra again. Then press the button; a window opens on Claude's settings file, \(ClaudeDesktop.fileName). Choose it and press Add. Everything else in the file is kept.")
                Button("Copy the Settings Entry") { copy(as: "desktop") { try desktopEntry } }
                PaneNote(copied == "desktop" ? "Copied." : "For adding it by hand instead: the entry goes inside \"mcpServers\" in that same file.")
            }
            Section("Access") {
                Button("Make a New Token…", role: .destructive) { confirmsReset = true }
                PaneNote("What you copy above contains a token only this Mac knows. Making a new one cuts off everything set up with the old one; copy and set up again afterwards.")
                if !isInstalled {
                    PaneNote("This copy of Ezra is not in the Applications folder. Set Claude up from the copy you keep there, or the setup stops working when this copy moves.")
                }
            }
        }
        .formStyle(.grouped)
        // The sandbox lets Ezra write only a file the user has chosen, so the user points at Claude's settings file once.
        .fileImporter(isPresented: $isChoosingConfig, allowedContentTypes: [.json]) { result in
            Alerts.shared.attempt("add Ezra to the Claude desktop app") {
                let file = try result.get()
                try ClaudeDesktop.add(command: helper, token: try MCPServer.storedToken(), toFileAt: file)
                addedToDesktop = true
            }
        }
        .fileDialogDefaultDirectory(ClaudeDesktop.folder)
        .fileDialogMessage("Choose \(ClaudeDesktop.fileName)")
        .fileDialogConfirmationLabel("Add")
        .confirmationDialog("Make a new token?", isPresented: $confirmsReset) {
            Button("Make a New Token", role: .destructive) {
                Alerts.shared.attempt("make a new token") {
                    try MCPServer.newToken()
                    server.apply()
                }
            }
        } message: {
            Text("Claude Code and the Claude desktop app lose access until you set them up again.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch server.status {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .starting: Text("Starting…").foregroundStyle(.secondary)
        case .listening: Label("Ready for Claude", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.Palette.logbook)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Brand.Palette.deadline).textSelection(.enabled)
        }
    }

    private var codeCommand: String {
        get throws { "claude mcp add --scope user ezra -e EZRA_MCP_TOKEN=\(try MCPServer.storedToken()) -- \"\(helper)\"" }
    }

    private var desktopEntry: String {
        get throws {
            let entry = ClaudeDesktop.entry(command: helper, token: try MCPServer.storedToken())
            let json = try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return "\"ezra\": " + String(decoding: json, as: UTF8.self)
        }
    }

    private func copy(as kind: String, _ text: () throws -> String) {
        Alerts.shared.attempt("copy the setup") {
            let text = try text()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = kind
        }
    }
}

/// The Claude desktop app's settings file, and putting Ezra into it.
enum ClaudeDesktop {
    static let fileName = "claude_desktop_config.json"

    /// Where Claude keeps that file: in the user's real Library, not in Ezra's own container.
    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appending(path: "Library/Application Support/Claude")
    }

    struct WrongFile: LocalizedError {
        let name: String
        var errorDescription: String? { "“\(name)” is not Claude's settings file. Choose \(ClaudeDesktop.fileName)." }
    }

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "Claude's settings file is not in a form Ezra can add to. Nothing was changed." }
    }

    static func entry(command: String, token: String) -> [String: Any] {
        ["command": command, "env": ["EZRA_MCP_TOKEN": token]]
    }

    /// The settings with Ezra among their servers; everything else as it was. Fails rather than writing anything
    /// when the settings are not a JSON object.
    static func adding(command: String, token: String, to settings: Data) throws -> Data {
        // A file that is empty so far is a file with no settings yet.
        let blank = settings.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        guard var whole = blank ? [:] : try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else { throw Unreadable() }
        guard var servers = whole["mcpServers"] == nil ? [:] : whole["mcpServers"] as? [String: Any] else { throw Unreadable() }
        servers["ezra"] = entry(command: command, token: token)
        whole["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: whole, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func add(command: String, token: String, toFileAt file: URL) throws {
        guard file.lastPathComponent == fileName else { throw WrongFile(name: file.lastPathComponent) }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        // Written in place: Ezra was given this one file, not the folder a safe-save would need.
        try adding(command: command, token: token, to: try Data(contentsOf: file)).write(to: file)
    }
}

