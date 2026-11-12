import FoundationModels
import SwiftData
import SwiftUI

/// This chat's own settings: instructions, how the chosen model should work, and which other models answer alongside it.
struct ChatParamsPanel: View {
    @Bindable var model: ChatModel

    var body: some View {
        Form {
            Section("Instructions for this chat") {
                TextField("For example: answer in one paragraph; this chat is about the Rome trip", text: $model.instructions, axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
            }
            Section("Replies") {
                Toggle("Suggest what to ask next", isOn: flag(\.followUps, default: true))
                Toggle("Show the model's reasoning", isOn: flag(\.showsThinking, default: false))
                    .help("Slower with Ollama: a reasoning model takes several times longer per step")
            }
            Section("Claude") {
                Picker("Effort", selection: $model.params.effort) {
                    Text("Default").tag(String?.none)
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                }
                Toggle("Search the web", isOn: flag(\.webSearch, default: true))
            }
            Section("Ollama") {
                Picker("Temperature", selection: $model.params.temperature) {
                    Text("Default").tag(Double?.none)
                    Text("Exact (0)").tag(Double?.some(0))
                    Text("Balanced (0.7)").tag(Double?.some(0.7))
                    Text("Varied (1.2)").tag(Double?.some(1.2))
                }
            }
            Section("Also ask") {
                ForEach(AssistantEngine.allCases.filter { $0 != model.engine }) { other in
                    Toggle(other.title, isOn: Binding(
                        get: { model.params.alsoAsk?.contains(other.rawValue) ?? false },
                        set: { on in
                            var asked = Set(model.params.alsoAsk ?? [])
                            if on { asked.insert(other.rawValue) } else { asked.remove(other.rawValue) }
                            model.params.alsoAsk = asked.isEmpty ? nil : asked.sorted()
                        }
                    ))
                }
                Text("Each message is also answered by these, for comparison. They can read your data but not change it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 520)
    }

    private func flag(_ field: WritableKeyPath<ChatParams, Bool?>, default standard: Bool) -> Binding<Bool> {
        Binding(get: { model.params[keyPath: field] ?? standard }, set: { model.params[keyPath: field] = $0 == standard ? nil : $0 })
    }
}

/// Messages waiting for the current reply to finish, and timers the assistant has running.
struct ChatWaitingStrip: View {
    let model: ChatModel
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.timers) { timer in
                HStack(spacing: 6) {
                    Image(systemName: "timer").foregroundStyle(Brand.Palette.accent)
                    Text(timer.label).lineLimit(1)
                    Text(timer.fires, style: .timer).monospacedDigit().foregroundStyle(Brand.Palette.secondary)
                    Button("Cancel", systemImage: "xmark") { model.cancel(timer) }.labelStyle(.iconOnly).help("Cancel this timer")
                }
            }
            ForEach(model.queue) { waiting in
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(Brand.Palette.secondary)
                    Text(waiting.text.isEmpty ? "\(waiting.files.count) file(s)" : waiting.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Edit", systemImage: "pencil") {
                        if let taken = model.unqueue(waiting.id) { draft = taken.text }
                    }
                    .help("Take it back into the box to change it")
                    Button("Remove", systemImage: "xmark") { _ = model.unqueue(waiting.id) }.help("Do not send this")
                }
                .labelStyle(.iconOnly)
            }
            if !model.queue.isEmpty {
                Text("Waiting messages are sent together when \(Brand.assistant) has finished.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Brand.Palette.secondary)
            }
        }
        .font(Brand.Fonts.subtitle)
        .foregroundStyle(Brand.Palette.ink)
        .buttonStyle(.hand)
    }
}

/// Guesses how the message being typed continues, with the model on this Mac. Nothing leaves the Mac.
@MainActor
@Observable
final class PromptPredictor {
    static let key = "assistant.autocomplete"
    private(set) var suggestion = ""
    private var work: Task<Void, Never>?

    /// Called on every change to the box. A guess is made once typing pauses, and dropped as soon as it resumes.
    func typed(_ draft: String, enabled: Bool) {
        work?.cancel()
        suggestion = ""
        guard enabled, draft.count >= 12, !draft.hasSuffix("\n"), case .available = SystemLanguageModel.default.availability else { return }
        work = Task {
            do {
                try await Task.sleep(for: .milliseconds(700))
                let session = LanguageModelSession(instructions: """
                    You complete a message a person is typing to their planner assistant. Reply with only the few words that \
                    would come next, at most eight, with no quotation marks and no explanation. If the message already reads as finished, reply with nothing.
                    """)
                let guess = try await session.respond(to: draft).content.trimmed
                guard !Task.isCancelled, !guess.isEmpty, guess.count <= 80 else { return }
                suggestion = draft.hasSuffix(" ") ? guess : " " + guess
            } catch is CancellationError {
                return
            } catch {
                // A guess is a convenience: when the model cannot make one there is simply none to show.
                Log.assistant.debug("No completion: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Hands over the guess and clears it.
    func take() -> String {
        defer { suggestion = "" }
        return suggestion
    }
}

/// Always there while a reply is in the making: what is happening, for how long, and a way out.
struct ChatWorkingStrip: View {
    let model: ChatModel

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.activity + "…").lineLimit(2)
            if let started = model.turnStarted {
                Text(started, style: .timer).monospacedDigit().foregroundStyle(Brand.Palette.secondary)
            }
            Spacer(minLength: 4)
            Button("Stop", systemImage: "stop.circle.fill") { model.stop() }
                .buttonStyle(.hand)
                .foregroundStyle(Brand.Palette.deadline)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop this reply (⌘.)")
        }
        .font(Brand.Fonts.subtitle)
        .foregroundStyle(Brand.Palette.ink)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Brand.Palette.accent.opacity(0.07), in: .rect(cornerRadius: 8))
    }
}
