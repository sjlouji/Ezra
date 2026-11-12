import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Ezra

/// A conversation with an attached file, tool steps, a to-do table, a page and a Markdown table, plus some history, for the assistant render.
@MainActor
func seedChat(_ chat: ChatModel, _ workspace: Workspace) throws {
    try chat.record(.user, "Plan the kitchen remodel")
    chat.togglePin(try #require(chat.thread))
    chat.newChat()
    try chat.record(.user, "Ideas for Eve's party")
    chat.newChat()
    try chat.record(
        .user, "Turn this into to-dos, show me today, and chart my projects",
        steps: [ChatStep(attached: ChatFile(name: "standup-transcript.vtt", text: "Daniel: I will send the deck by Friday."))]
    )
    let task = try workspace.addToDo(title: "Send the deck", schedule: .on(.now), tags: ["Work"])
    var added = ChatStep(tool: "addTask", label: "Add to-do", detail: "deadline: 2026-11-13 · tags: Work · title: Send the deck")
    (added.state, added.changed, added.todos, added.result) = (.done, true, [task.uuid], "Added task Send the deck")
    (added.subject, added.seconds, added.input) = ("Send the deck", 0.4, "{\n  \"deadline\" : \"2026-11-13\",\n  \"tags\" : [\"Work\"],\n  \"title\" : \"Send the deck\"\n}")
    let said = ChatStep(narration: "The transcript has one commitment. I'll add it, show today, then chart your projects.")
    let running = ChatStep(tool: "showPage", label: "Make page", detail: "", subject: "Open to-dos by project", started: Date(timeIntervalSinceNow: -193))
    var shown = ChatStep(tool: "showTasks", label: "Show table", detail: "list: today · title: Today")
    (shown.state, shown.table) = (.done, ChatTable(title: "Today", todos: try workspace.tasks(in: .today).prefix(3).map(\.uuid)))
    var page = ChatStep(tool: "showPage", label: "Make page", detail: "title: Open to-dos by project")
    (page.state, page.page) = (.done, ChatPage(title: "Open to-dos by project", html: "<h3>Chart</h3><svg width='300' height='60'><rect width='220' height='24' fill='#1F63D2'/></svg>"))
    var thought = ChatStep(thought: "The transcript has one commitment: Daniel sends the deck by Friday.")
    thought.id = UUID()
    var plan = ChatStep(tool: "plan", label: "Plan", detail: "")
    (plan.state, plan.plan) = (.done, [PlanLine(title: "Read the transcript", done: true), PlanLine(title: "Add the to-dos", done: true), PlanLine(title: "Chart the projects", done: false)])
    let suggestions = ChatStep(tool: ChatStep.followUps, label: "", detail: "Move it to Friday | Who else owes something?", state: .done)
    chat.params.alsoAsk = ["ollama"]
    chat.instructions = "Keep it short."
    try chat.record(.assistant, """
        Done. **Send the deck** is on today.

        ## Who owes what
        | Person | Item | Due |
        |---|---|---|
        | Daniel | Send the deck | Friday |
        | Julia | Review the budget | next week |
        """, steps: [ChatStep(tool: ChatStep.engine, label: "Claude", detail: "", state: .done), thought, said, plan, added, shown, running, suggestions])
    _ = page
    let spec = try JSONDecoder().decode(Dashboard.self, from: Data("""
        {"subtitle": "Open work across your projects", "kpis": [{"label": "Open to-dos", "value": 108, "note": "3 overdue", "tone": "bad"},
          {"label": "Due this week", "value": 9}, {"label": "Done this week", "value": 26, "note": "up from 14", "tone": "good"}],
         "charts": [{"title": "Open by project", "type": "bar", "items": [{"label": "Move to the New Flat", "value": 12}, {"label": "Recipe Blog", "value": 8},
            {"label": "Throw Party for Eve", "value": 7}, {"label": "Vacation in Rome", "value": 6}]},
           {"title": "By area", "type": "donut", "items": [{"label": "Home", "value": 15}, {"label": "Work", "value": 13}, {"label": "Family", "value": 16}]}],
         "notes": ["The move holds the most open work.", "Three to-dos are past their deadline."]}
        """.utf8))
    var board = ChatStep(tool: "showDashboard", label: "Show dashboard", detail: "", subject: "My workload", seconds: 0.1)
    (board.state, board.page) = (.done, ChatPage(title: "My workload", html: spec.html(title: "My workload")))
    chat.newChat()
    try chat.record(.user, "Create an artifact on my work load")
    try chat.record(.assistant, "Here is your workload at a glance.", steps: [board])
    chat.queue = [QueuedMessage(text: "Also remind me to call Julia", files: [])]
    chat.move(try #require(chat.thread), toFolder: "Work")
}

@MainActor
struct ChatContentTests {
    @Test func repliesRenderTablesCodeAndOrdinaryLines() {
        let blocks = ReplyMarkdown.blocks("""
            ## Plan
            | Step | Owner |
            |:--|--:|
            | Book | Sam |
            | Pack |
            after
            ```swift
            let a = 1
            ```
            | not | a table
            - item
            """)
        #expect(blocks == [
            .line(.heading(level: 2, text: "Plan")),
            .table(header: ["Step", "Owner"], rows: [["Book", "Sam"], ["Pack"]]),
            .line(.paragraph("after")),
            .code("let a = 1"),
            .line(.paragraph("| not | a table")),
            .line(.bullet("item")),
        ])
        #expect(ReplyMarkdown.blocks("```\nunclosed") == [.code("unclosed")])
    }

    @Test func aPageIsLoadedWithAPolicyThatBlocksTheNetwork() {
        let bare = ChatPage(title: "T", html: "<p>Hi</p>").document
        #expect(bare.hasPrefix("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\""))
        #expect(bare.contains("default-src 'none'") && bare.hasSuffix("</style></head><body><p>Hi</p></body></html>"))
        let full = ChatPage(title: "T", html: "<html><HEAD lang='en'><title>x</title></head><body></body></html>").document
        #expect(full.hasPrefix("<html><HEAD lang='en'><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\""))
        #expect(full.hasSuffix("<title>x</title></head><body></body></html>"))
    }

    @Test func aPageThatTriesToLoadItsDataIsSentBackToTheModel() throws {
        let (_, container) = try makeWorkspace()
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        let bad = box.run("showPage", ToolInput(value: .object(["title": .string("C"), "html": .string("<script>fetch('/api/x')</script>")])))
        #expect(bad.failed && bad.page == nil && bad.text.contains("it uses fetch(, and a page cannot load anything"))
        let good = box.run("showPage", ToolInput(value: .object(["title": .string("C"), "html": .string("<a href='#top'>x</a><svg></svg>")])))
        #expect(!good.failed && good.page?.title == "C")
    }

    @Test func filesAreReadAsTextOrRefusedWithTheReason() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chatfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = folder.appending(path: name)
            try data.write(to: url)
            return url
        }
        let transcript = try await ChatFileReader.read(try file("call.vtt", Data("WEBVTT\n\nSam: ship it Friday".utf8)))
        #expect(transcript == ChatFile(name: "call.vtt", text: "WEBVTT\n\nSam: ship it Friday"))

        let styled = NSAttributedString(string: "Decision: move the launch.")
        let rtf = try #require(styled.rtf(from: NSRange(location: 0, length: styled.length)))
        #expect(try await ChatFileReader.read(try file("notes.rtf", rtf)).text == "Decision: move the launch.")

        await #expect(throws: ChatFileError.unreadable("photo.png")) { try await ChatFileReader.read(try file("photo.png", Data([0xFF, 0xD8, 0xFF, 0x00, 0x80]))) }
        await #expect(throws: ChatFileError.empty("blank.txt")) { try await ChatFileReader.read(try file("blank.txt", Data("  \n".utf8))) }
        let long = String(repeating: "a", count: ChatFileReader.limit + 1)
        await #expect(throws: ChatFileError.tooLong(name: "big.txt", characters: long.count)) { try await ChatFileReader.read(try file("big.txt", Data(long.utf8))) }
    }

    @Test func anAttachedFileGoesToClaudeNowAndInLaterTurnsAndAPageComesBack() async throws {
        let (_, container) = try makeWorkspace()
        let html = "<html><head></head><body>" + String(repeating: "<i>bar</i>", count: 30) + "</body></html>"
        let pageCall = try JSONEncoder().encode(JSONValue.object([
            "stop_reason": .string("tool_use"),
            "content": .array([.object([
                "type": .string("tool_use"), "id": .string("toolu_9"), "name": .string("showPage"),
                "input": .object(["title": .string("Timeline"), "html": .string(html)]),
            ])]),
        ]))
        let done = #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "Here is the timeline."}]}"#
        let claude = FakeClaude([(200, String(decoding: pageCall, as: UTF8.self)), (200, done), (200, done)])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)

        await chat.send("", files: [ChatFile(name: "call.vtt", text: "Sam: ship it Friday")])
        let asked = try #require(chat.messages.first)
        #expect(asked.text.hasPrefix("Read the attached file.") && asked.steps.map(\.detail) == ["call.vtt"])
        let sent = try #require(try claude.body(0)["messages"]?.items.first?["content"]?.text)
        #expect(sent.hasSuffix("<file name=\"call.vtt\">\nSam: ship it Friday\n</file>"))

        let reply = try #require(chat.messages.last)
        #expect(reply.text == "Here is the timeline." && reply.steps.first?.page == ChatPage(title: "Timeline", html: html))
        // The step's one-line label does not carry the whole page.
        #expect((reply.steps.first?.detail.count ?? 0) < 120)

        await chat.send("And who owns it?")
        let later = try claude.body(2)["messages"]?.items ?? []
        #expect(later.first?["content"]?.text?.contains("Sam: ship it Friday") == true && later.count == 3)
    }

    @Test func aFileTooLongForTheMacIsRefusedWithAPointerToClaude() async throws {
        let (_, container) = try makeWorkspace()
        let chat = makeChat(container)
        await chat.send("Summarise", files: [ChatFile(name: "long.txt", text: String(repeating: "word ", count: 2000))])
        #expect(chat.messages.last?.role == .failure)
        #expect(chat.messages.last?.text.hasPrefix("The attached text is too long for the model on this Mac (10,000 characters") == true)
    }

    /// White paper with one line of large black type, as a picture.
    private func picture(saying words: String, size: CGSize = CGSize(width: 1800, height: 500)) throws -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (words as NSString).draw(at: NSPoint(x: 60, y: size.height / 2 - 50), withAttributes: [.font: NSFont.systemFont(ofSize: 90), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image
    }

    @Test func picturesAndScannedPDFsAreReadByLookingAtThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "scans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try picture(saying: "Invoice 4821 due Friday")
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let pngURL = folder.appending(path: "invoice.png")
        try png.write(to: pngURL)

        let photo = try await ChatFileReader.read(pngURL)
        #expect(photo.text.hasPrefix("Text read from the picture:") && photo.text.contains("4821"), "\(photo.text)")
        let jpeg = try #require(photo.image)
        #expect(jpeg.count <= ChatFileReader.pictureBytes && jpeg.prefix(2) == Data([0xFF, 0xD8]))

        // A PDF whose page is only that picture: no typed text, so the words are read off the page.
        let scan = PDFDocument()
        scan.insert(try #require(PDFPage(image: image)), at: 0)
        let pdfURL = folder.appending(path: "scan.pdf")
        #expect(scan.write(to: pdfURL))
        let scanned = try await ChatFileReader.read(pdfURL)
        #expect(scanned.image == nil && scanned.text.contains("4821"), "\(scanned.text)")
    }

    @Test func aPictureGoesToClaudeAsAPictureAndStaysWithTheMessage() async throws {
        let (_, container) = try makeWorkspace()
        let done = #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "A receipt."}]}"#
        let claude = FakeClaude([(200, done), (200, done)])
        let chat = makeChat(container, engine: .claude, key: "k", transport: claude.transport)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        await chat.send("What is this?", files: [ChatFile(name: "receipt.jpg", text: "(A picture. No text was found in it.)", image: jpeg)])
        #expect(chat.messages.first?.steps.first?.image == jpeg)
        let content = try claude.body(0)["messages"]?.items.first?["content"]?.items ?? []
        #expect(content.first?["type"] == .string("image") && content.first?["source"]?["data"] == .string(jpeg.base64EncodedString()))
        #expect(content.last?["text"]?.text?.hasPrefix("What is this?") == true)
        // It is sent again with later turns, so follow-up questions can still see it.
        await chat.send("And the total?")
        #expect(try claude.body(1)["messages"]?.items.first?["content"]?.items.first?["type"] == .string("image"))
    }
}
