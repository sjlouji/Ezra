import Foundation
import SwiftData

/// What can be set for one chat. Anything left alone falls back to the account's defaults, then the model's.
struct ChatParams: Codable, Equatable, Sendable {
    /// Claude: how hard to think: "low", "medium" or "high"; nil for Claude's own default.
    var effort: String?
    /// Ollama: 0 is exact, higher is more varied; nil for the model's default.
    var temperature: Double?
    /// Claude: whether it may search the web and read pages.
    var webSearch: Bool?
    /// Show the model's reasoning with each reply. Slower with Ollama.
    var showsThinking: Bool?
    /// Suggest things to ask next under each reply.
    var followUps: Bool?
    /// Other models that also answer each message, for comparison. They can read but not change anything.
    var alsoAsk: [String]?

    var usesWeb: Bool { webSearch ?? true }
    var thinks: Bool { showsThinking ?? false }
    var suggests: Bool { followUps ?? true }
    var extraEngines: [AssistantEngine] { (alsoAsk ?? []).compactMap { AssistantEngine(rawValue: $0) } }
}

extension ChatThread {
    var params: ChatParams {
        get {
            guard let paramsData else { return ChatParams() }
            do {
                return try JSONDecoder().decode(ChatParams.self, from: paramsData)
            } catch {
                Log.assistant.error("A chat's parameters could not be read, so its defaults are used: \(String(describing: error), privacy: .public)")
                return ChatParams()
            }
        }
        set { paramsData = newValue == ChatParams() ? nil : try? JSONEncoder().encode(newValue) } // plain values always encode
    }
}

/// A message typed while a reply was still being written. Waiting messages are sent together when it is done.
struct QueuedMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var files: [ChatFile]
}

/// One step of a plan the model keeps while it works through something with several parts.
struct PlanLine: Codable, Sendable, Equatable {
    var title: String
    var done: Bool
}

enum ChatText {
    static let followUpPrefix = "Follow-ups:"
    /// Added to what a capable model is told, when suggestions are on.
    static let followUpRule = """
        End every reply with one last line in exactly this form, and nothing after it: \
        "Follow-ups: first | second | third". They are three short things the user might ask next, written as the user would say them.
        """

    /// Splits a reply into what to show and the suggestions on its last line. While a reply is still arriving, a half-written
    /// suggestions line is hidden too.
    static func splitFollowUps(_ reply: String) -> (text: String, followUps: [String]) {
        var lines = reply.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmed.hasPrefix(followUpPrefix) }),
              lines[(index + 1)...].allSatisfy({ $0.trimmed.isEmpty })
        else { return (reply, []) }
        let suggestions = lines[index].trimmed.dropFirst(followUpPrefix.count).split(separator: "|").map { String($0).trimmed }.filter { !$0.isEmpty }
        lines.removeSubrange(index...)
        return (lines.joined(separator: "\n").trimmed, Array(suggestions.prefix(3)))
    }

    /// A conversation as Markdown, for sharing or saving.
    @MainActor
    static func markdown(of thread: ChatThread) -> String {
        var parts = ["# \(thread.title.isEmpty ? "Chat" : thread.title)", "_\(Brand.name), \(thread.createdAt.formatted(date: .abbreviated, time: .shortened))_"]
        for message in thread.sortedMessages {
            let steps = (try? message.steps()) ?? [] // an export leaves out steps it cannot read rather than failing
            let speaker = message.roleRaw == "user" ? "You" : steps.first { $0.tool == ChatStep.engine }?.label ?? Brand.assistant
            var body = message.text
            let files = steps.filter { $0.tool == ChatStep.attachment }.map { "📎 \($0.detail)" }
            let did = steps.filter { $0.changed && $0.state == .done }.map { "- \($0.label): \($0.detail)" }
            if !files.isEmpty { body += "\n\n" + files.joined(separator: "\n") }
            if !did.isEmpty { body += "\n\n" + did.joined(separator: "\n") }
            parts.append("**\(speaker)**\n\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }
}
