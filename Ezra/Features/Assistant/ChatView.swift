import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var model: ChatModel
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var app
    @AppStorage("assistant.showsHistory") private var showsHistory = true
    @State private var historyPopover = false
    @State private var draft = ""
    @State private var files: [ChatFile] = []
    @State private var choosingFiles = false
    /// Files still being read (a scanned PDF takes a moment).
    @State private var reading = 0
    @State private var showsParams = false
    @State private var predictor = PromptPredictor()
    @AppStorage(PromptPredictor.key) private var autocompletes = true
    @FocusState private var draftFocused: Bool

    /// What the assistant can do, each with a request to try. Claude can do more than the model on this Mac.
    private var examples: [(symbol: String, title: String, prompt: String)] {
        var all = [
            ("list.bullet.rectangle", "Ask about your work", "Show me what is on my plate today"),
            ("plus.circle", "Add and change things", "Remind me tonight at 9 pm to call Mom"),
        ]
        if model.engine != .onDevice {
            all += [
                ("lightbulb", "Think something through", "Help me plan a project: a weekend trip to the hills"),
                ("paperclip", "Work from a file", "Attach a meeting transcript, then ask: turn this into a project with to-dos"),
                ("chart.bar.xaxis", "See it as a picture", "Make a chart of my open to-dos by project"),
            ]
            if model.engine == .claude { all.append(("globe", "Look something up", "Search the web for the best time of year to visit Rome")) }
        } else {
            all.append(("folder", "Summarise", "Summarise my projects"))
        }
        return all
    }

    private var intro: String {
        switch model.engine {
        case .claude:
            "Claude answers. What you write, the files you attach and the to-dos it reads are sent to Anthropic."
        case .ollama:
            "\(model.ollamaModel ?? "An Ollama model") answers, on this Mac. It is private and free, and cannot reach the web."
        case .onDevice:
            "Apple's model on this Mac answers. It is private and free, and best at short requests about your to-dos. Switch to Ollama or Claude (top right) for files, ideas and charts."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            // Beside the chat when there is room; otherwise the history opens from its button.
            let wide = geometry.size.width >= 720
            HStack(spacing: 0) {
                if wide && showsHistory {
                    ChatHistory(model: model)
                        .frame(width: 220)
                        .background(Brand.Palette.sidebar.opacity(0.6))
                    Divider().overlay(Brand.Palette.hairline)
                }
                VStack(alignment: .leading, spacing: 0) {
                    header(wide: wide)
                    if let reason = model.unavailableReason {
                        ContentUnavailableView {
                            Label("\(Brand.assistant) unavailable", systemImage: "sparkles")
                        } description: {
                            Text(reason)
                        } actions: {
                            if model.engine != .onDevice { Button("Open Settings") { openSettings() } }
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        conversation
                        composer
                    }
                }
                // The same centred column as the to-do screens.
                .frame(maxWidth: 660)
                .frame(maxWidth: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    attach(urls)
                    return true
                }
            }
        }
        .background(Brand.Palette.page)
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 19))
                .foregroundStyle(Brand.Palette.accent)
            Text(Brand.assistant)
                .font(Brand.Fonts.title)
                .foregroundStyle(Brand.Palette.ink)
            Spacer()
            Picker("Model", selection: $model.engine) {
                ForEach(AssistantEngine.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isResponding)
            .help("Which model answers: Apple's on this Mac, a larger Ollama model on this Mac, or Claude (your API key; web search)")
            .task { if model.engine == .ollama { await model.refreshOllama() } }
            Group {
                Button("Chat Settings", systemImage: "slider.horizontal.3") { showsParams = true }
                    .foregroundStyle(model.params == ChatParams() && model.instructions.isEmpty ? Brand.Palette.secondary : Brand.Palette.accent)
                    .help("This chat's instructions and settings")
                    .popover(isPresented: $showsParams, arrowEdge: .bottom) { ChatParamsPanel(model: model) }
                if let thread = model.thread {
                    ShareLink(item: ChatText.markdown(of: thread), preview: SharePreview(thread.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share or save this chat as text")
                }
                Button("History", systemImage: "sidebar.left") {
                    if wide { showsHistory.toggle() } else { historyPopover = true }
                }
                .help("Earlier chats")
                .popover(isPresented: $historyPopover, arrowEdge: .bottom) {
                    ChatHistory(model: model).frame(width: 260, height: 380)
                }
                Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .opacity(model.messages.isEmpty || model.isResponding ? 0.35 : 1)
                    .disabled(model.messages.isEmpty || model.isResponding)
                    .help("Start a new chat")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.hand)
            .font(.system(size: 14))
            .foregroundStyle(Brand.Palette.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 54)
        .padding(.bottom, 10)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        Text(intro)
                            .font(Brand.Fonts.subtitle)
                            .foregroundStyle(Brand.Palette.secondary)
                        ForEach(examples, id: \.title) { example in
                            Button {
                                draft = example.prompt
                                draftFocused = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: example.symbol)
                                        .foregroundStyle(Brand.Palette.accent)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(example.title).font(Brand.Fonts.rowBold).foregroundStyle(Brand.Palette.ink)
                                        Text(example.prompt).font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Brand.Palette.sidebar, in: .rect(cornerRadius: 9))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.hand)
                            .help("Put this in the box to edit or send")
                        }
                    }
                    ForEach(model.messages) { message in
                        let isLast = message.id == model.messages.last?.id
                        MessageBubble(
                            message: message, isStreaming: model.isResponding && isLast,
                            followUp: isLast && message.role == .assistant ? { send($0) } : nil
                        )
                        .id(message.id)
                    }
                    if model.isResponding { ChatWorkingStrip(model: model).id("working") }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages.last) {
                if model.isResponding { proxy.scrollTo("working", anchor: .bottom) } else if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.queue.isEmpty || !model.timers.isEmpty { ChatWaitingStrip(model: model, draft: $draft) }
            if !predictor.suggestion.isEmpty {
                // What the on-device model guesses comes next; Tab takes it.
                Button {
                    draft += predictor.take()
                } label: {
                    Text("⇥ \(predictor.suggestion.trimmed)").font(Brand.Fonts.subtitle).foregroundStyle(Brand.Palette.secondary).lineLimit(1)
                }
                .help("Press Tab to add this")
            }
            if !files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files) { file in
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text(file.name).lineLimit(1)
                            Button("Remove", systemImage: "xmark") { files.removeAll { $0.id == file.id } }
                                .labelStyle(.iconOnly)
                                .help("Remove this file")
                        }
                        .font(Brand.Fonts.subtitle)
                        .foregroundStyle(Brand.Palette.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(Brand.Palette.page, in: .capsule)
                    }
                }
            }
            HStack(alignment: .bottom) {
                Button("Attach", systemImage: "paperclip") { choosingFiles = true }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.Palette.secondary)
                    .help("Attach a transcript, document or picture (or drop it on the chat)")
                TextField(files.isEmpty ? "Ask or tell \(Brand.assistant)…" : "Say what to make from the file…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($draftFocused)
                    .onSubmit { send(draft) }
                    .onChange(of: draft) { predictor.typed(draft, enabled: autocompletes) }
                    .onKeyPress(.tab) {
                        guard !predictor.suggestion.isEmpty else { return .ignored }
                        draft += predictor.take()
                        return .handled
                    }
                Button("Voice Mode", systemImage: model.speaksReplies ? "speaker.wave.2.fill" : "speaker.slash") { model.speaksReplies.toggle() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14))
                    .foregroundStyle(model.speaksReplies ? Brand.Palette.accent : Brand.Palette.secondary)
                    .help(model.speaksReplies ? "Voice mode is on: replies are read aloud, and what you dictate is sent when you stop speaking" : "Voice mode: read replies aloud and send dictation automatically")
                if reading > 0 { ProgressView().controlSize(.small).help("Reading the file…") }
                DictationButton(text: $draft) { if model.speaksReplies { send(draft) } }.font(.system(size: 15))
                Button("Send", systemImage: "arrow.up.circle.fill") { send(draft) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .disabled((draft.trimmed.isEmpty && files.isEmpty) || reading > 0)
                    .help(model.isResponding ? "Send when \(Brand.assistant) has finished" : "Send")
            }
        }
        .buttonStyle(.hand)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(Brand.Palette.field.opacity(0.8), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .onAppear {
            draftFocused = true
            if let waiting = app.assistantDraft { (draft, app.assistantDraft) = (waiting, nil) }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { chosen in
            Alerts.shared.attempt("attach the file") { attach(try chosen.get()) }
        }
    }

    /// Reads each file. One that cannot be read is reported and left out; the others are still attached.
    private func attach(_ urls: [URL]) {
        for url in urls {
            reading += 1
            Task {
                defer { reading -= 1 }
                do {
                    let file = try await ChatFileReader.read(url)
                    if file.image != nil, files.count(where: { $0.image != nil }) >= ChatFileReader.pictureLimit {
                        throw ChatFileError.tooManyPictures
                    }
                    files.append(file)
                } catch {
                    Alerts.shared.report("attach \(url.lastPathComponent)", error)
                }
            }
        }
    }

    /// While a reply is being written the message joins the queue instead.
    private func send(_ text: String) {
        let attached = files
        (draft, files) = ("", [])
        Task { await model.send(text, files: attached) }
    }
}
