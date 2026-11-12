import Foundation

/// One tool call shown in the chat: what the assistant did, with what, and how it went.
struct ChatStep: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable { case running, done, failed }

    var id = UUID()
    var tool: String
    /// What the chat calls the tool: "Add to-do", "Searched the web".
    var label: String
    /// The arguments in one line.
    var detail: String
    /// What came back; shown when the step is opened.
    var result = ""
    var state = State.running
    /// True when the call changed the user's data.
    var changed = false
    /// To-dos the call created or changed.
    var todos: [UUID] = []
    var table: ChatTable?
    var page: ChatPage?
    /// What was sent to the tool, as formatted JSON; shown when the step is opened.
    var input: String?
    /// The one thing the call is about (a title, a search), for the step's headline.
    var subject: String?
    /// When the call began, and how long it took once it has ended.
    var started: Date?
    var seconds: Double?
    /// A plan the model is working through, as it stood at this call.
    var plan: [PlanLine]?
    /// An attached picture, as a small JPEG.
    var image: Data?
    /// Web pages a search returned.
    var sources: [Source] = []

    struct Source: Codable, Sendable, Equatable {
        var title: String
        var url: String
    }

    var symbol: String {
        switch tool {
        case "web_search": "globe"
        case "web_fetch": "doc.text.magnifyingglass"
        case "showTasks": "tablecells"
        case "showPage", "buildArtifact", "showDashboard", "showWorkload": "chart.bar.xaxis"
        case ChatStep.thinking: "brain"
        case "setTimer": "timer"
        case "delegate": "person.2"
        case "plan": "checklist"
        case "notify": "bell"
        case ChatStep.attachment: "paperclip"
        default: changed ? "pencil.circle" : "magnifyingglass.circle"
        }
    }
}

/// A table of to-dos the assistant put in the chat. Rows are read live from the store, so they stay current and can be changed in place.
struct ChatTable: Codable, Sendable, Equatable {
    var title: String
    var todos: [UUID]
}

/// An interactive page the assistant made for the chat: a chart, a timeline, a board. It is shown in a web view that cannot reach the network.
struct ChatPage: Codable, Sendable, Equatable {
    var title: String
    var html: String
    /// For an artifact built with the React kit: the one component file the model wrote. `html` is then empty.
    var code: String?

    /// The page as loaded: the model's HTML with a policy that allows only what is written in the page itself.
    var document: String {
        if let code { return ArtifactKit.document(for: code) }
        let policy = """
            <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
            style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: blob:; font-src data:">\
            <style>body { font: 14px -apple-system, sans-serif; margin: 12px; color: #26282C; }</style>
            """
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: head, with: html[head] + policy)
        }
        return "<!doctype html><html><head>\(policy)</head><body>\(html)</body></html>"
    }
}

extension ChatStep {
    /// The tool name of a step that records a file the user attached; its `result` is the file's text.
    static let attachment = "attachment"
    /// Marks which model wrote a reply, when several answer; its `label` is the model's name.
    static let engine = "engine"
    /// Carries the suggestions under a reply, separated by " | " in `detail`.
    static let followUps = "followUps"
    /// The model's reasoning before it answered; `result` holds it.
    static let thinking = "thinking"
    /// Something the model said between tool calls; `result` holds it. Kept in order with the calls around it.
    static let narration = "say"
    /// Steps that are not tool calls and so are not listed as such.
    static let hidden: Set<String> = [attachment, engine, followUps, narration]

    init(narration text: String) {
        self.init(tool: Self.narration, label: "", detail: "", result: text, state: .done)
    }

    /// The model's reasoning before a reply, shortened to a line with the whole of it one click away.
    init(thought: String) {
        let text = thought.trimmed
        self.init(tool: Self.thinking, label: "Thought", detail: text.count > 90 ? text.prefix(90) + "…" : text, result: text, state: .done)
    }

    init(attached file: ChatFile) {
        self.init(tool: Self.attachment, label: "Attached", detail: file.name, result: file.text, state: .done, image: file.image)
    }
}

extension ChatMessage {
    /// The tool calls made while producing this reply.
    func steps() throws -> [ChatStep] {
        guard let stepsData else { return [] }
        return try JSONDecoder().decode([ChatStep].self, from: stepsData)
    }

    func setSteps(_ steps: [ChatStep]) throws {
        stepsData = steps.isEmpty ? nil : try JSONEncoder().encode(steps)
    }
}
