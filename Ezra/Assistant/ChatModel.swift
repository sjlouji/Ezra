import Foundation
import FoundationModels
import SwiftData

/// The assistant. It reads and changes the store through `AgentToolbox`, with either engine.
/// Conversations are saved, so they survive quitting and sync with everything else.
@MainActor
@Observable
final class ChatModel {
    struct Message: Identifiable, Equatable {
        enum Role: String { case user, assistant, failure }
        let id: UUID
        let role: Role
        var text: String
        /// The tool calls made while producing this reply.
        var steps: [ChatStep] = []
        /// Replies saved before steps existed list what they changed here.
        var changes: [String] = []
    }

    /// The conversation on screen; nil before the first message of a new one.
    private(set) var thread: ChatThread?
    var isResponding = false
    /// What the assistant is doing right now, in a few words, and since when; shown while it works.
    var activity = ""
    var turnStarted: Date?
    /// The model call in flight, so it can be stopped.
    var working: Task<String, Error>?
    /// This chat's settings and the instructions the user gave it. Changes are saved with the chat.
    var params = ChatParams() { didSet { saveSettings() } }
    var instructions = "" { didSet { saveSettings() } }
    /// Messages typed while a reply was being written; they are sent together when it is done.
    var queue: [QueuedMessage] = []
    /// Timers the assistant set that have not fired yet.
    var timers: [ChatTimer] = []
    /// Read each finished reply aloud (voice mode).
    var speaksReplies = false
    private(set) var hasClaudeKey = false
    var engine: AssistantEngine {
        didSet {
            defaults.set(engine.rawValue, forKey: Self.engineKey)
            session = nil
        }
    }

    /// The Ollama models installed on this Mac; empty until `refreshOllama` has asked.
    private(set) var ollamaModels: [String] = []
    /// Why the list is empty, when asking Ollama failed.
    private(set) var ollamaProblem: String?
    /// The Ollama model that answers; nil until one is chosen.
    var ollamaModel: String? {
        didSet { defaults.set(ollamaModel, forKey: Self.ollamaModelKey) }
    }

    /// The reply being produced. It is saved once, when it is complete, not on every word.
    var pending: Message?
    var session: LanguageModelSession?
    let container: ModelContainer
    let reminders: ReminderScheduler?
    let transport: LineTransport
    let defaults: UserDefaults
    let readKey: () throws -> Data?
    let voice = ReplyVoice()
    /// The instructions that apply to every chat, set in Settings.
    static let accountInstructionsKey = "assistant.instructions"
    private let writeKey: (Data?) throws -> Void
    private static let engineKey = "assistant.engine"
    private static let ollamaModelKey = "assistant.ollamaModel"

    init(
        container: ModelContainer, reminders: ReminderScheduler? = .shared, transport: @escaping LineTransport = HTTP.liveLines,
        defaults: UserDefaults = .standard,
        readKey: @escaping () throws -> Data? = { try Keychain.read(Keychain.claudeKey) },
        writeKey: @escaping (Data?) throws -> Void = { try Keychain.write($0, Keychain.claudeKey) }
    ) {
        (self.container, self.reminders, self.transport, self.readKey, self.writeKey) = (container, reminders, transport, readKey, writeKey)
        self.defaults = defaults
        ollamaModel = defaults.string(forKey: Self.ollamaModelKey)
        engine = defaults.string(forKey: Self.engineKey).flatMap { AssistantEngine(rawValue: $0) } ?? .onDevice
        Alerts.shared.attempt("read the Claude key") { hasClaudeKey = try readKey() != nil }
    }

    var messages: [Message] {
        let saved = (thread?.sortedMessages ?? []).map { stored in
            var message = Message(
                id: stored.uuid, role: Message.Role(rawValue: stored.roleRaw) ?? .assistant, text: stored.text, changes: stored.changes
            )
            do {
                message.steps = try stored.steps()
            } catch {
                Log.assistant.error("A reply's steps could not be read: \(String(describing: error), privacy: .public)")
                var unreadable = ChatStep(tool: "unreadable", label: "Steps could not be read", detail: "")
                (unreadable.id, unreadable.state, unreadable.result) = (stored.uuid, .failed, error.localizedDescription)
                message.steps = [unreadable]
            }
            return message
        }
        return saved + (pending.map { [$0] } ?? [])
    }

    /// Why the chosen engine cannot be used right now; nil when it can.
    var unavailableReason: String? {
        if engine == .claude { return hasClaudeKey ? nil : ClaudeError.noKey.errorDescription }
        if engine == .ollama { return ollamaModel == nil ? OllamaError.noModel.errorDescription : nil }
        return switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings to use \(Brand.assistant)."
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading. Try again shortly."
        case .unavailable(let reason):
            "The on-device model is unavailable (\(String(describing: reason)))."
        }
    }

    /// Stores the user's Claude API key in the Keychain, or removes it when `key` is nil.
    func setClaudeKey(_ key: String?) throws {
        try writeKey(key.map { Data($0.trimmed.utf8) })
        hasClaudeKey = key != nil
        if key == nil, engine == .claude { engine = .onDevice }
    }

    /// Asks Ollama which models are installed. The first one becomes the choice when none was made or the chosen one is gone.
    func refreshOllama() async {
        do {
            ollamaModels = try await OllamaClient(transport: transport).models()
            ollamaProblem = ollamaModels.isEmpty ? OllamaError.noModelsInstalled.errorDescription : nil
            if ollamaModel.map({ !ollamaModels.contains($0) }) ?? true { ollamaModel = ollamaModels.first }
        } catch {
            Log.assistant.error("Could not list Ollama models: \(String(describing: error), privacy: .public)")
            ollamaModels = []
            ollamaProblem = (error as? OllamaError ?? .notRunning).errorDescription
        }
    }

    // MARK: Conversations

    /// Starts a blank conversation. The one on screen stays in the history.
    func newChat() {
        guard !isResponding else { return }
        (thread, session) = (nil, nil)
        (params, instructions) = (ChatParams(), "")
    }

    /// Shows an earlier conversation. Claude reads its earlier turns; the on-device model starts fresh from here.
    func open(_ earlier: ChatThread) {
        guard !isResponding else { return }
        // Its settings first, while no chat is attached, so loading them does not write them back.
        (thread, session) = (nil, nil)
        (params, instructions) = (earlier.params, earlier.instructions)
        thread = earlier
    }

    /// Files a chat in a folder; an empty name takes it out.
    func move(_ conversation: ChatThread, toFolder folder: String) {
        Alerts.shared.attempt("move the chat") {
            conversation.folder = folder.trimmed
            try container.mainContext.save()
        }
    }

    private func saveSettings() {
        guard let thread, thread.params != params || thread.instructions != instructions else { return }
        Alerts.shared.attempt("save the chat's settings") {
            (thread.params, thread.instructions) = (params, instructions)
            try container.mainContext.save()
        }
    }

    func delete(_ conversation: ChatThread) {
        guard !isResponding else { return }
        if thread == conversation { newChat() }
        Alerts.shared.attempt("delete the conversation") {
            container.mainContext.delete(conversation)
            try container.mainContext.save()
        }
    }

    func togglePin(_ conversation: ChatThread) {
        Alerts.shared.attempt("pin the conversation") {
            conversation.pinned.toggle()
            try container.mainContext.save()
        }
    }

    func rename(_ conversation: ChatThread, to title: String) {
        guard !title.trimmed.isEmpty else { return }
        Alerts.shared.attempt("rename the conversation") {
            conversation.title = title.trimmed
            try container.mainContext.save()
        }
    }

    /// Saves one message to the conversation on screen, starting the conversation if this is its first.
    func record(_ role: Message.Role, _ text: String, steps: [ChatStep] = []) throws {
        let context = container.mainContext
        let conversation = thread ?? {
            let started = ChatThread(title: String(text.prefix(60)))
            (started.params, started.instructions) = (params, instructions)
            context.insert(started)
            return started
        }()
        let message = ChatMessage(roleRaw: role.rawValue, text: text)
        try message.setSteps(steps)
        context.insert(message)
        message.thread = conversation
        conversation.updatedAt = .now
        try context.save()
        thread = conversation
    }
}
