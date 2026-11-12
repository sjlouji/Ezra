import Foundation
import SwiftData

/// The tools the chat carries out itself, because they take time or reach outside the store: timers, notifications, sub-agents.
extension ChatModel {
    // MARK: Tools the chat carries out itself

    func extras(for engine: AssistantEngine, _ box: AgentToolbox) -> [String: @MainActor @Sendable (ToolInput) async throws -> ToolOutcome] {
        [
            "setTimer": { [weak self] input in
                guard let minutes = Double(try input.required("minutes")), minutes > 0, minutes <= 24 * 60 else {
                    throw WorkspaceError.badDate(input.string("minutes") ?? "")
                }
                let timer = ChatTimer(
                    label: try input.required("label"), fires: .now.addingTimeInterval(minutes * 60), prompt: input.string("prompt"), thread: self?.thread?.uuid
                )
                self?.start(timer)
                return ToolOutcome(text: "Timer \"\(timer.label)\" set for \(timer.fires.formatted(date: .omitted, time: .shortened)).")
            },
            "notify": { [weak self] input in
                self?.notify(try input.required("title"), try input.required("message"))
                return ToolOutcome(text: "The notification was shown.")
            },
            "delegate": { [weak self] input in
                guard let self else { throw AgentToolError.unavailable("delegate") }
                let tasks = Array(input.strings("tasks").prefix(4))
                // Sub-agents get the same tools, except handing work on again.
                var theirs = box
                theirs.extras["delegate"] = nil
                let (context, helper) = (try self.context(), theirs)
                // Started together; each waits on its own model replies, so they overlap.
                let jobs = tasks.map { task in
                    Task { @MainActor in
                        let turn = [ChatTurn(fromUser: true, text: task)]
                        var quiet = ChatParams()
                        quiet.followUps = false
                        return engine == .claude
                            ? try await self.claudeHelper(helper, quiet).answer(turn, context: context)
                            : try await self.ollamaHelper(helper, quiet).answer(turn, context: context)
                    }
                }
                var answers: [String] = []
                for job in jobs { answers.append(try await job.value) }
                return ToolOutcome(text: tasks.indices.map { "## Sub-agent \($0 + 1): \(tasks[$0])\n\(answers[$0])" }.joined(separator: "\n\n"))
            },
        ]
    }

    /// A sub-agent's model: the same as the chat's, without writing into the reply on screen.
    private func claudeHelper(_ box: AgentToolbox, _ params: ChatParams) throws -> ClaudeAgent {
        var agent = try claude(box, params)
        (agent.onText, agent.onActivity) = ({ _ in }, { _ in })
        return agent
    }

    private func ollamaHelper(_ box: AgentToolbox, _ params: ChatParams) throws -> OllamaAgent {
        var agent = try ollama(box, params)
        (agent.onText, agent.onActivity) = ({ _ in }, { _ in })
        return agent
    }

    /// Counts a timer down. Timers live only while the app is open.
    func start(_ timer: ChatTimer) {
        timers.append(timer)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(timer.fires.timeIntervalSinceNow, 0))) // cancelled only when the app quits
            guard let self, self.timers.contains(timer) else { return }
            self.timers.removeAll { $0 == timer }
            self.notify("Timer: \(timer.label)", timer.prompt ?? "Time is up.")
            // Its prompt goes into the chat it was set in, if that chat is still the one open.
            if let prompt = timer.prompt, timer.thread == self.thread?.uuid {
                await self.send("The timer \"\(timer.label)\" has ended. \(prompt)")
            }
        }
    }

    func cancel(_ timer: ChatTimer) {
        timers.removeAll { $0 == timer }
    }
}
