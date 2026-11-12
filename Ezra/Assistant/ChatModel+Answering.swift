import AppKit
import AVFoundation
import Foundation
import FoundationModels
import SwiftData
@preconcurrency import UserNotifications

/// A timer the assistant set. When it ends the user is notified and its prompt, if any, goes into the chat it was set in.
struct ChatTimer: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let fires: Date
    let prompt: String?
    let thread: UUID?
}

/// Reads replies aloud in voice mode.
@MainActor
final class ReplyVoice {
    private let synthesizer = AVSpeechSynthesizer()

    func say(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        // Spoken without the Markdown marks.
        synthesizer.speak(AVSpeechUtterance(string: text.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)))
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

extension ChatModel {
    // MARK: Sending

    /// Sends what the user typed, with any files they attached. Files alone are enough: the model is then asked what it can
    /// make of them. While a reply is being written the message waits; everything waiting is sent together when it is done.
    func send(_ text: String, files: [ChatFile] = []) async {
        guard !(text.trimmed.isEmpty && files.isEmpty) else { return }
        guard !isResponding else { return queue.append(QueuedMessage(text: text.trimmed, files: files)) }
        let request = text.trimmed.isEmpty
            ? "Read the attached \(files.count == 1 ? "file" : "files"). Summarise what is in it and say what you could create from it."
            : text.trimmed
        do {
            try record(.user, request, steps: files.map(ChatStep.init(attached:)))
        } catch {
            return Alerts.shared.report("save the message", error)
        }
        (isResponding, turnStarted, activity) = (true, .now, "Thinking")
        defer {
            (isResponding, pending, turnStarted, working) = (false, nil, nil, nil)
        }
        voice.stop()
        let others = params.extraEngines.filter { $0 != engine }
        let asked: [ChatTurn]
        do {
            asked = try turns()
        } catch {
            return Alerts.shared.report("read the conversation", error)
        }
        // The chosen model answers with every tool; any others asked for comparison can read but not change anything.
        await answer(as: engine, request, files, asked, readOnly: false, labelled: !others.isEmpty)
        for other in others { await answer(as: other, request, files, asked, readOnly: true, labelled: true) }

        isResponding = false
        guard !queue.isEmpty else { return }
        let waiting = queue
        queue = []
        await send(waiting.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), files: waiting.flatMap(\.files))
    }

    /// Takes a waiting message back out, to edit or drop.
    func unqueue(_ id: UUID) -> QueuedMessage? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        return queue.remove(at: index)
    }

    /// One model's reply to the last message, saved to the conversation when it is complete.
    private func answer(as engine: AssistantEngine, _ request: String, _ files: [ChatFile], _ asked: [ChatTurn], readOnly: Bool, labelled: Bool) async {
        pending = Message(id: UUID(), role: .assistant, text: "")
        if labelled { pending?.steps = [ChatStep(tool: ChatStep.engine, label: engine.title, detail: "", state: .done)] }
        var reply = Message(id: UUID(), role: .assistant, text: "")
        do {
            var box = AgentToolbox(
                container: container, reminders: reminders, tools: AgentTools.all.filter { !readOnly || !$0.changesData }
            ) { [weak self] step in self?.show(step) }
            box.strict = engine != .onDevice
            if !readOnly { box.extras = extras(for: engine, box) }
            let (toolbox, context) = (box, try context())
            // In a task of its own, so Stop can cancel it wherever it is waiting.
            let job = Task { @MainActor in
                switch engine {
                case .claude: try await self.claude(toolbox, self.params).answer(asked, context: context)
                case .ollama: try await self.ollama(toolbox, self.params).answer(asked, context: context)
                case .onDevice: try await self.askOnDevice(request, files, toolbox, keepsSession: !readOnly)
                }
            }
            working = job
            let whole = try await job.value
            let (text, followUps) = ChatText.splitFollowUps(whole)
            reply.text = text
            if !followUps.isEmpty {
                show(ChatStep(tool: ChatStep.followUps, label: "", detail: followUps.joined(separator: " | "), state: .done))
            }
        } catch where working?.isCancelled == true || error is CancellationError || (error as? URLError)?.code == .cancelled {
            // Stopped by the user: what was written so far is kept.
            session = nil
            reply.text = [ChatText.splitFollowUps(pending?.text ?? "").text, "*Stopped.*"].filter { !$0.isEmpty }.joined(separator: "\n\n")
        } catch {
            Log.assistant.error("Assistant turn failed: \(String(describing: error), privacy: .public)")
            // A failed on-device turn (most often a full context window) leaves the session unusable, so the next message starts a new one.
            session = nil
            let fresh = engine == .onDevice ? "\n\(Brand.assistant) starts a fresh conversation with your next message." : ""
            reply = Message(id: UUID(), role: .failure, text: error.localizedDescription + fresh)
        }
        do {
            try record(reply.role, reply.text, steps: pending?.steps ?? [])
        } catch {
            Alerts.shared.report("save the reply", error)
        }
        finished(reply)
    }

    /// Tells the user a reply is ready when they are not looking, and reads it aloud in voice mode.
    private func finished(_ reply: Message) {
        if speaksReplies, reply.role == .assistant { voice.say(reply.text) }
        // No scheduler means a test: nothing is posted to the real Notification Centre.
        guard reminders != nil, !NSApp.isActive else { return }
        notify(reply.role == .failure ? "\(Brand.assistant) could not answer" : "\(Brand.assistant) answered", String(reply.text.prefix(140)))
    }

    func notify(_ title: String, _ message: String) {
        guard reminders != nil else { return }
        let content = UNMutableNotificationContent()
        (content.title, content.body, content.sound) = (title, message, .default)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.assistant.error("A notification could not be shown: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Stops the reply being written. Anything a tool already did stays done; messages waiting in the queue are dropped.
    func stop() {
        queue = []
        working?.cancel()
    }

    /// Adds a tool call to the reply being produced, or updates it when it finishes.
    func show(_ step: ChatStep) {
        if !ChatStep.hidden.contains(step.tool), step.tool != ChatStep.thinking {
            activity = step.state == .running ? "\(step.label): \(step.detail.prefix(60))" : "Thinking"
        }
        if let index = pending?.steps.firstIndex(where: { $0.id == step.id }) {
            pending?.steps[index] = step
        } else {
            pending?.steps.append(step)
        }
    }

    // MARK: What the models are given

    /// What the model should know about right now.
    func context() throws -> String {
        let now = Date.now
        let workspace = Workspace(context: container.mainContext, reminders: reminders)
        let tags = try workspace.allTags()
        // The newest memories that fit; both local models have little room.
        var remembered: [String] = []
        for fact in try workspace.memories().reversed() where remembered.joined().count + fact.count <= 1200 { remembered.insert(fact, at: 0) }
        let memory = remembered.isEmpty ? "" : "\nWhat you remember about the user:\n" + remembered.map { "- \($0)" }.joined(separator: "\n")
        // The account's standing instructions, then this chat's own.
        let wishes = [defaults.string(forKey: Self.accountInstructionsKey) ?? "", instructions].map(\.trimmed).filter { !$0.isEmpty }
        let asked = wishes.isEmpty ? "" : "\nThe user's instructions for you:\n" + wishes.joined(separator: "\n")
        return """
            Now: \(now.formatted(.dateTime.weekday(.wide))) \(DayText.string(moment: now)). Dates are written yyyy-MM-dd, times HH:mm (24-hour).
            Tags in use: \(tags.isEmpty ? "none yet" : tags.joined(separator: ", ")).\(memory)\(asked)
            """
    }

    func claude(_ box: AgentToolbox, _ params: ChatParams) throws -> ClaudeAgent {
        guard let stored = try readKey(), let key = String(data: stored, encoding: .utf8) else { throw ClaudeError.noKey }
        var agent = ClaudeAgent(client: ClaudeClient(key: key, transport: transport), box: box) { [weak self] in self?.streamed($0) }
        agent.params = params
        agent.onActivity = { [weak self] in self?.activity = $0 }
        return agent
    }

    func ollama(_ box: AgentToolbox, _ params: ChatParams) throws -> OllamaAgent {
        guard let model = ollamaModel else { throw OllamaError.noModel }
        var agent = OllamaAgent(client: OllamaClient(transport: transport), model: model, box: box) { [weak self] in self?.streamed($0) }
        agent.params = params
        agent.onActivity = { [weak self] in self?.activity = $0 }
        return agent
    }

    /// Shows a reply as it arrives, without the suggestions line that ends it.
    private func streamed(_ text: String) {
        pending?.text = ChatText.splitFollowUps(text).text
    }

    /// The conversation so far as text, files included. A failed turn is not replayed as if it were an answer.
    func turns() throws -> [ChatTurn] {
        try (thread?.sortedMessages ?? [])
            .filter { $0.roleRaw != Message.Role.failure.rawValue && !$0.text.trimmed.isEmpty }
            .map { message in
                let steps = try message.steps()
                return ChatTurn(
                    fromUser: message.roleRaw == Message.Role.user.rawValue, text: Self.withFiles(message.text, steps),
                    images: steps.compactMap(\.image)
                )
            }
    }

    /// A message as the model reads it: what was typed, followed by the text of each attached file.
    static func withFiles(_ text: String, _ steps: [ChatStep]) -> String {
        let files = steps.filter { $0.tool == ChatStep.attachment }
        return ([text] + files.map { "<file name=\"\($0.detail)\">\n\($0.result)\n</file>" }).joined(separator: "\n\n")
    }

    /// `keepsSession` false answers once in a throwaway session (when the on-device model is only asked for comparison).
    private func askOnDevice(_ request: String, _ files: [ChatFile], _ box: AgentToolbox, keepsSession: Bool) async throws -> String {
        let attached = files.reduce(0) { $0 + $1.text.count }
        guard attached <= ChatFileReader.onDeviceLimit else { throw ChatFileError.tooLongForThisMac(characters: attached) }
        let session = try (keepsSession ? self.session : nil) ?? LanguageModelSession(
            tools: box.tools.filter(\.onDevice).map { try OnDeviceTool($0, box: box) },
            instructions: """
                You are \(Brand.assistant), the assistant inside \(Brand.name), the user's personal project manager. It holds their tasks, projects and notes.
                Always use the tools to read the user's data before answering about it; never invent tasks, projects or notes.
                When the user asks you to add, complete, reschedule or write something, call the matching tool, then confirm in one short sentence.
                "Remind me at a time" is a task with a reminder at exactly that time. Pass the day the user said as "when". \
                Give a new task one or two fitting tags yourself; never ask the user for them.
                Meetings, calls and appointments with a time are events: use addEvent and listEvents for them, not tasks.
                If a tool returns an error, tell the user what it said.
                When asked what is planned, due or on a list, read it and name the tasks; never answer with counts alone.
                For their workload, an overview, or an "artifact" about their to-dos, call showWorkload and add one sentence.
                When asked to summarise, say in two or three sentences what stands out (where most of the work is, what is due soon, \
                what has not started) instead of repeating the list. Keep answers short. Use plain lists and **bold** for names.
                """
        )
        if keepsSession { self.session = session }
        activity = "Thinking"
        for try await snapshot in session.streamResponse(to: "\(try context())\n\n\(Self.withFiles(request, files.map(ChatStep.init(attached:))))") {
            pending?.text = snapshot.content
            activity = "Writing the reply"
        }
        return pending?.text ?? ""
    }
}
