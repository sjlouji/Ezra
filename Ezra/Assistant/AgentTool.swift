import Foundation
import SwiftData

/// Any JSON value. Tool arguments and Claude's message blocks are passed around in this form.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    var text: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var items: [JSONValue] {
        if case .array(let values) = self { values } else { [] }
    }

    static func parse(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}

/// The arguments a model gave a tool.
struct ToolInput: Sendable {
    let value: JSONValue

    /// A text argument; nil when it is missing or blank.
    func string(_ name: String) -> String? {
        value[name]?.text.nonEmpty
    }

    func required(_ name: String) throws -> String {
        guard let found = string(name) else { throw AgentToolError.missing(name) }
        return found
    }

    func bool(_ name: String) -> Bool {
        if case .bool(let flag) = value[name] { flag } else { false }
    }

    /// A list argument. Small models sometimes send one comma-separated string instead; that is accepted too.
    func strings(_ name: String) -> [String] {
        switch value[name] {
        case .array(let values): values.compactMap { $0.text.nonEmpty }
        case .string(let joined): joined.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        default: []
        }
    }

    /// The one argument that says what a call is about, when it has one.
    var subject: String? {
        if let named = ["title", "name", "query", "label", "fact", "url"].lazy.compactMap({ string($0) }).first { return named }
        let tasks = strings("tasks")
        return tasks.isEmpty ? string("list") ?? string("day") ?? string("date") : "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
    }

    /// The arguments exactly as the model sent them, laid out to be read.
    var formatted: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } // a JSON value always encodes
    }

    /// The arguments as a short line for the chat: "title: Call bank · when: today".
    var summary: String {
        guard case .object(let fields) = value else { return "" }
        return fields.sorted { $0.key < $1.key }.compactMap { key, value in
            switch value {
            // Long text (notes, a page's HTML) is shortened: this line is a label, not the content.
            case .string(let text): text.trimmed.isEmpty ? nil : "\(key): \(text.count > 80 ? text.prefix(80) + "…" : text)"
            case .bool(let flag): "\(key): \(flag ? "yes" : "no")"
            case .array(let values): values.isEmpty ? nil : "\(key): \(values.compactMap(\.text).joined(separator: ", "))"
            default: nil
            }
        }
        .joined(separator: " · ")
    }
}

enum AgentToolError: LocalizedError {
    case missing(String)
    case unknownTool(String)
    case pageLoadsData(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Nothing was done: the \"\(name)\" argument is missing or empty. Call the tool again with it."
        case .unknownTool(let name): "There is no tool called \(name)."
        case .unavailable(let name): "\(name) cannot be used here."
        case .pageLoadsData(let loader):
            "The page was not shown: it uses \(loader), and a page cannot load anything. Read the data with the other tools first, then call showPage again with the values written into the HTML."
        }
    }
}

/// What a tool hands back: text for the model, and what the chat should show with it.
struct ToolOutcome: Sendable {
    var text: String
    /// True when the tool could not do what was asked; `text` then says why.
    var failed = false
    /// To-dos this call created or changed; the chat links to them.
    var todos: [UUID] = []
    /// A table of to-dos to show in the chat.
    var table: ChatTable?
    /// An interactive page to show in the chat.
    var page: ChatPage?
    /// A plan to show as a checklist.
    var plan: [PlanLine]?
}

/// One thing the assistant can do, described once and offered to whichever model is answering.
struct AgentTool: Sendable {
    struct Parameter: Sendable {
        enum Kind: Sendable, Equatable {
            case text, flag, list
            /// A structured argument, described by its own JSON Schema. Not offered to the on-device model.
            case object(JSONValue)
        }
        let name: String
        let about: String
        var kind: Kind = .text
        var required = false
        /// The only values allowed, when the choice is closed.
        var options: [String] = []
        /// False for arguments only Claude is offered; the on-device model's context is small.
        var onDevice = true
    }

    let name: String
    /// What the chat calls it: "Add to-do".
    let label: String
    let about: String
    let parameters: [Parameter]
    var changesData = false
    /// Offered to the on-device model as well. Its context is small, so it gets the essentials only.
    var onDevice = true
    let body: @MainActor @Sendable (Workspace, ToolInput) throws -> ToolOutcome

    /// The JSON Schema of the arguments, as Claude wants it.
    var schema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters {
            var property: [String: JSONValue] = ["description": .string(parameter.about)]
            switch parameter.kind {
            case .text: property["type"] = .string("string")
            case .flag: property["type"] = .string("boolean")
            case .list:
                property["type"] = .string("array")
                property["items"] = .object(["type": .string("string")])
            case .object(let schema):
                if case .object(let fields) = schema { property.merge(fields) { described, _ in described } }
            }
            if !parameter.options.isEmpty { property["enum"] = .array(parameter.options.map(JSONValue.string)) }
            properties[parameter.name] = .object(property)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(parameters.filter(\.required).map { .string($0.name) }),
        ])
    }
}

/// Runs tools against the store and reports each call, so the chat can show what the assistant is doing.
struct AgentToolbox: Sendable {
    let container: ModelContainer
    let reminders: ReminderScheduler?
    let tools: [AgentTool]
    /// Whether every required argument must be there before a tool runs. Claude and Ollama are held to it, so a
    /// skipped argument (tags, most often) is sent back to be filled in; the small on-device model is not, because
    /// it stops and asks the user instead of trying again.
    var strict = false
    /// Tools that take time or reach outside the store (a timer, a sub-agent, a notification), by name. The chat supplies
    /// them; a tool listed in `tools` without one here answers that it cannot be used.
    var extras: [String: @MainActor @Sendable (ToolInput) async throws -> ToolOutcome] = [:]
    /// Called when a tool starts (no result yet) and again when it finishes.
    let report: @MainActor @Sendable (ChatStep) -> Void

    init(
        container: ModelContainer, reminders: ReminderScheduler?, tools: [AgentTool] = AgentTools.all,
        report: @escaping @MainActor @Sendable (ChatStep) -> Void
    ) {
        (self.container, self.reminders, self.tools, self.report) = (container, reminders, tools, report)
    }

    /// Runs one tool. A failure is logged, shown in the chat and returned to the model as text,
    /// so it can tell the user or try again with a better argument.
    @MainActor
    func run(_ name: String, _ input: ToolInput) -> ToolOutcome {
        let tool = tools.first { $0.name == name }
        var step = begin(name, input)
        report(step)
        defer {
            step.seconds = step.started.map { Date.now.timeIntervalSince($0) }
            report(step)
        }
        do {
            guard let tool else { throw AgentToolError.unknownTool(name) }
            if strict, let skipped = tool.parameters.first(where: { parameter in
                parameter.required && (parameter.kind == .list ? input.strings(parameter.name).isEmpty : input.value[parameter.name] == nil)
            }) {
                throw AgentToolError.missing(skipped.name)
            }
            let outcome = try tool.body(Workspace(context: container.mainContext, reminders: reminders), input)
            (step.result, step.todos, step.table, step.changed) = (outcome.text, outcome.todos, outcome.table, tool.changesData)
            (step.page, step.plan) = (outcome.page, outcome.plan)
            step.state = .done
            return outcome
        } catch {
            Log.assistant.error("Tool \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            (step.result, step.state) = (error.localizedDescription, .failed)
            return ToolOutcome(text: "Error: \(error.localizedDescription)", failed: true)
        }
    }

    /// A step for a call that is starting: what it is, what it was given, and when.
    private func begin(_ name: String, _ input: ToolInput) -> ChatStep {
        ChatStep(
            tool: name, label: tools.first { $0.name == name }?.label ?? name, detail: input.summary,
            input: input.formatted, subject: input.subject, started: .now
        )
    }

    /// Runs a tool that may take time. Ordinary tools go through `run`.
    @MainActor
    func runAsync(_ name: String, _ input: ToolInput) async -> ToolOutcome {
        guard let extra = extras[name] else { return run(name, input) }
        var step = begin(name, input)
        report(step)
        defer {
            step.seconds = step.started.map { Date.now.timeIntervalSince($0) }
            report(step)
        }
        do {
            let outcome = try await extra(input)
            (step.result, step.state, step.changed) = (outcome.text, .done, true)
            return outcome
        } catch {
            Log.assistant.error("Tool \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            (step.result, step.state) = (error.localizedDescription, .failed)
            return ToolOutcome(text: "Error: \(error.localizedDescription)", failed: true)
        }
    }
}
