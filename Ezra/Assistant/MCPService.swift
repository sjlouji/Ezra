import Foundation
import SwiftData

/// Ezra as a tool server for Claude (the Model Context Protocol): Claude Code and the Claude desktop app can read and
/// change the user's to-dos, projects, notes and calendar through the same tools Ezra's own assistant uses.
/// This part answers one request; `MCPServer` is the door the requests come through.
@MainActor
enum MCPService {
    /// The tools offered: those that read and change data. The ones that draw in Ezra's chat are left out.
    static let tools: [AgentTool] = [
        AgentTools.listTasks, AgentTools.listProjects, AgentTools.listAreasAndTags, AgentTools.search, AgentTools.listNotes,
        AgentTools.readNote, AgentTools.listEvents, AgentTools.dateMath, AgentTools.addTask, AgentTools.updateTask,
        AgentTools.completeTask, AgentTools.addProject, AgentTools.addArea, AgentTools.writeNote, AgentTools.attachNote, AgentTools.addEvent,
    ]
    private static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The reply to one JSON-RPC message, or to a batch of them. Nil when nothing is owed: a notification, or a batch of them.
    static func respond(to body: Data, container: ModelContainer) -> Data? {
        let reply: JSONValue?
        switch try? JSONDecoder().decode(JSONValue.self, from: body) {
        case .array(let batch):
            let answers = batch.compactMap { answer($0, container: container) }
            reply = answers.isEmpty ? nil : .array(answers)
        case .object(let message):
            reply = answer(.object(message), container: container)
        default:
            reply = failure(.null, -32700, "The request is not JSON.")
        }
        return reply.flatMap { try? JSONEncoder().encode($0) } // a JSON value always encodes
    }

    private static func answer(_ message: JSONValue, container: ModelContainer) -> JSONValue? {
        // A message without an id is a notification: it is taken note of and not answered.
        guard let id = message["id"], id != .null else { return nil }
        guard let method = message["method"]?.text else { return failure(id, -32600, "The request names no method.") }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.text ?? ""
            return success(id, .object([
                "protocolVersion": .string(versions.contains(asked) ? asked : versions[0]),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("ezra"), "title": .string(Brand.name), "version": .string(appVersion)]),
                "instructions": .string("""
                    \(Brand.name) is the user's planner on their Mac: to-dos, projects, areas, notes and calendar. Read with the \
                    list and search tools before answering about their data. Titles identify tasks, projects and notes; use \
                    them exactly as listed. Dates are yyyy-MM-dd. Give every new task one to three tags.
                    """),
            ]))
        case "ping":
            return success(id, .object([:]))
        case "tools/list":
            return success(id, .object(["tools": .array(tools.map { tool in
                .object(["name": .string(tool.name), "title": .string(tool.label), "description": .string(tool.about), "inputSchema": tool.schema])
            })]))
        case "tools/call":
            guard let name = params["name"]?.text else { return failure(id, -32602, "The call names no tool.") }
            var box = AgentToolbox(container: container, reminders: .shared, tools: tools) { _ in }
            box.strict = true
            let outcome = box.run(name, ToolInput(value: params["arguments"] ?? .object([:])))
            Log.assistant.info("Claude ran \(name, privacy: .public): \(outcome.failed ? "failed" : "done", privacy: .public)")
            return success(id, .object([
                "content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]), "isError": .bool(outcome.failed),
            ]))
        default:
            return failure(id, -32601, "Ezra does not know the method \(method).")
        }
    }

    private static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    private static func success(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func failure(_ id: JSONValue, _ code: Double, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(code), "message": .string(message)])])
    }
}
