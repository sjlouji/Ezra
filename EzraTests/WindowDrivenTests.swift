import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Ezra

/// The real Today screen in a window: a to-do dragged down to This Evening, and back.
@MainActor
struct TodaySectionDragTests {
    @Test func aToDoIsDraggedBetweenTodayAndThisEvening() async throws {
        let (workspace, container) = try makeWorkspace()
        let first = try workspace.addToDo(title: "First", schedule: .on(.now))
        let second = try workspace.addToDo(title: "Second", schedule: .on(.now))
        let app = AppModel()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(container: container, app: app).modelContainer(container))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))

        func frame(of todo: ToDo) throws -> CGRect { try #require(app.slots.values.first { $0.todo == todo }?.frame) }

        // Nothing is in the evening yet: its header shows once the drag has begun, and takes the drop.
        let origin = try frame(of: first)
        app.dragChanged(.todo(first), at: CGPoint(x: origin.midX, y: origin.midY), from: origin)
        try await Task.sleep(for: .seconds(0.8))
        let header = try #require(app.zones.values.first { if case .evening(true) = $0.target { true } else { false } }?.frame)
        app.dragChanged(.todo(first), at: CGPoint(x: header.midX, y: header.midY), from: origin)
        #expect(app.dropHint == "Move to \(Brand.Words.thisEvening)")
        app.dragEnded()
        #expect(first.evening)

        // Now the evening has a row: the other to-do is dropped on that row.
        try await Task.sleep(for: .seconds(0.8))
        let (from, onto) = (try frame(of: second), try frame(of: first))
        app.dragChanged(.todo(second), at: CGPoint(x: from.midX, y: from.midY), from: from)
        app.dragChanged(.todo(second), at: CGPoint(x: onto.midX, y: onto.midY), from: from)
        #expect(app.dropHint == "Move to \(Brand.Words.thisEvening)")
        app.dragEnded()
        #expect(second.evening)

        // Both are in the evening and the day has no rows: while dragging, the day offers a place to drop.
        try await Task.sleep(for: .seconds(0.8))
        let start = try frame(of: second)
        app.dragChanged(.todo(second), at: CGPoint(x: start.midX, y: start.midY), from: start)
        try await Task.sleep(for: .seconds(0.8))
        let day = try #require(app.zones.values.first { if case .evening(false) = $0.target { true } else { false } }?.frame)
        app.dragChanged(.todo(second), at: CGPoint(x: day.midX, y: day.midY), from: start)
        app.dragEnded()
        #expect(!second.evening && first.evening)

        // With a row in each part, a to-do goes back up by being dropped on the day's row.
        try await Task.sleep(for: .seconds(0.8))
        let (low, high) = (try frame(of: first), try frame(of: second))
        app.dragChanged(.todo(first), at: CGPoint(x: low.midX, y: low.midY), from: low)
        app.dragChanged(.todo(first), at: CGPoint(x: high.midX, y: high.midY), from: low)
        app.dragEnded()
        #expect(!first.evening)
    }
}

/// The note editor in a real window, driven through its text views as the keyboard would.
@MainActor
struct BlockEditorTests {
    private func fields(in view: NSView) -> [NSTextView] {
        (view.subviews.flatMap(fields) + [view as? MarkdownTextView].compactMap { $0 })
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    @Test func typingBuildsBlocksAndTheNoteStaysMarkdown() async throws {
        let (workspace, container) = try makeWorkspace()
        let note = try workspace.addNote(title: "Scratch")
        let app = AppModel()
        app.destination = .note(note)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(container: container, app: app).modelContainer(container))
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1.5))

        /// The block the keyboard is in.
        func current() throws -> NSTextView { try #require(window.firstResponder as? MarkdownTextView, "no block has the keyboard") }
        /// Lets the editor catch up: the screen redraws and the keyboard moves to the block it was sent to.
        func settle() async throws {
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                if window.firstResponder is MarkdownTextView { break }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        func type(_ text: String) async throws {
            try current().insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await settle()
        }
        func press(_ key: Selector) async throws {
            try current().doCommand(by: key)
            try await settle()
        }
        let enter = #selector(NSResponder.insertNewline(_:)), back = #selector(NSResponder.deleteBackward(_:))

        // An empty note is one empty line. Opening it has written nothing.
        let first = try #require(fields(in: host).first)
        #expect(note.body.isEmpty)
        window.makeFirstResponder(first)

        // "# " makes a heading; Return after it starts plain text.
        try await type("# ")
        try await type("Plan")
        try await press(enter)
        try await type("Ship **retries**")
        try await press(enter)
        // "- " then a letter makes a bullet; Return carries the list on; Tab nests; Return on an empty item steps back out.
        try await type("- ")
        try await type("one")
        try await press(enter)
        try await type("two")
        try await press(#selector(NSResponder.insertTab(_:)))
        try await press(enter)
        try await press(enter)
        try await press(enter)
        // "[] " makes a checkbox.
        try await type("[] ")
        try await type("test it")
        #expect(note.body == "# Plan\nShip **retries**\n- one\n  - two\n- [ ] test it")

        // Backspace at the start of the checkbox makes it plain text, and again joins it to the line above.
        try current().setSelectedRange(NSRange(location: 0, length: 0))
        try await press(back)
        #expect(note.body.hasSuffix("  - two\ntest it"))
        try await press(back)
        #expect(note.body == "# Plan\nShip **retries**\n- one\n  - twotest it")
        #expect(try current().selectedRange().location == 3)

        // Pasted lines become blocks.
        try await press(enter)
        try await type("> quoted\n1. a\n2. b")
        #expect(note.body == "# Plan\nShip **retries**\n- one\n  - two\n> quoted\n1. a\n2. btest it")
        #expect(fields(in: host).count == NoteBlocks.parse(note.body).count)
    }
}


/// Long lines wrap, and every block is as tall as its wrapped text, so nothing is drawn over the block below.
@MainActor
struct BlockEditorLayoutTests {
    @Test func wrappedBlocksAreAsTallAsTheirText() async throws {
        let (workspace, container) = try makeWorkspace()
        let long = "Use 3 dashes for an em-dash. Use 2 dashes for ranges (ex., it's all in chapters 12--14). Three dots will be converted to an ellipsis. "
        let note = try workspace.addNote(title: "Wrap", body: "\(long)\(long)\(long)\n- \(long)\(long)\n> \(long)\(long)\nshort\n| a | b |\n|---|---|\n| 1 | 2 |\nend")
        let app = AppModel()
        app.destination = .note(note)
        for width in [1100.0, 760.0] {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: RootView(container: container, app: app).modelContainer(container))
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .seconds(1.5))
            func fields(_ view: NSView) -> [NSTextView] { view.subviews.flatMap(fields) + [view as? MarkdownTextView].compactMap { $0 } }
            let found = fields(host).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            #expect(found.count >= 5)
            var bottom = CGFloat.infinity
            for field in found {
                let layout = try #require(field.layoutManager), box = try #require(field.textContainer)
                layout.ensureLayout(for: box)
                let needed = layout.usedRect(for: box).height
                let frame = field.convert(field.bounds, to: nil)
                print("EZRA-WRAP width \(width) field \(Int(frame.width))x\(Int(frame.height)) needs \(Int(needed)) top \(Int(frame.maxY)) text \(field.string.prefix(12))")
                #expect(frame.height >= needed - 1, "a block is shorter than its text: \(field.string.prefix(20))")
                #expect(frame.maxY <= bottom + 1, "a block is drawn over the one above")
                bottom = frame.minY
            }
            window.close()
        }
    }
}

/// Columns in a real window: the cells sit side by side, every block is as tall as its text, what follows the layout
/// starts below its tallest cell, and typing in a cell stays in that cell.
@MainActor
struct BlockLayoutWindowTests {
    @Test func columnsSitSideBySideAndTypingStaysInItsCell() async throws {
        let (workspace, container) = try makeWorkspace()
        let long = "Use 3 dashes for an em-dash. Use 2 dashes for ranges. Three dots will be converted to an ellipsis. "
        let note = try workspace.addNote(title: "Columns", body: "<!-- layout 1:1 -->\nLEFT \(long)\(long)\(long)\n<!-- cell -->\nRIGHT short\n<!-- /layout -->\nAFTER")
        let app = AppModel()
        app.destination = .note(note)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(container: container, app: app).modelContainer(container))
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1.5))

        func fields(_ view: NSView) -> [NSTextView] { view.subviews.flatMap(fields) + [view as? MarkdownTextView].compactMap { $0 } }
        func field(_ start: String) throws -> NSTextView { try #require(fields(host).first { $0.string.hasPrefix(start) }, "no block starts with \(start)") }
        func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
        let (left, right, after) = (try field("LEFT"), try field("RIGHT"), try field("AFTER"))

        // Side by side, starting level; window coordinates grow upwards.
        #expect(frame(left).maxX < frame(right).minX)
        #expect(abs(frame(left).maxY - frame(right).maxY) < 2)
        // The long cell wraps inside its half and is as tall as its text; the line after the layout is below it.
        let layout = try #require(left.layoutManager), box = try #require(left.textContainer)
        layout.ensureLayout(for: box)
        #expect(frame(left).height >= layout.usedRect(for: box).height - 1 && frame(left).height > 60)
        #expect(frame(left).width < 420)
        #expect(frame(after).maxY < frame(left).minY)

        // Return in the right cell makes a new line in that cell, not in the note or the other cell.
        window.makeFirstResponder(right)
        right.setSelectedRange(NSRange(location: 5, length: 0))
        right.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .seconds(0.6))
        #expect(note.body.hasSuffix("<!-- cell -->\nRIGHT\n short\n<!-- /layout -->\nAFTER"))
        #expect((window.firstResponder as? NSTextView)?.string == " short")
    }
}

