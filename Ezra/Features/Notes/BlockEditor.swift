import AppKit
import SwiftUI

/// A note's text as blocks, edited in place: each line shows as what it is (a heading, a list item, a checkbox, code,
/// a table) while it is typed, blocks are dragged by their handle, and layouts put blocks side by side in columns and
/// grids. The note itself is stored as Markdown.
struct BlockEditor: View {
    typealias CellRef = NoteBlocks.CellRef

    @Binding var markdown: String
    @State var blocks: [NoteBlock] = []
    /// The block the keyboard was last sent to, and the request that sent it.
    @State var focusID: UUID?
    @State var focus = FocusRequest(token: 0, location: 0)
    /// The blocks under the pointer: a block in a cell, and the layout around it.
    @State var hovered: Set<UUID> = []
    /// Where each block and each layout cell sits, for dragging.
    @State var frames: [UUID: CGRect] = [:]
    @State var cellFrames: [CellRef: CGRect] = [:]
    /// The block being dragged and where the pointer is, in the editor's own coordinates.
    @State var drag: (id: UUID, at: CGPoint)?
    /// The block whose actions are showing.
    @State var menuFor: UUID?

    static let space = "blocks"
    static let gutter: CGFloat = 40

    var body: some View {
        let numbers = NoteBlocks.numbers(in: blocks)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    row(block, numbers: numbers, inCell: false)
                }
                // Clicking under the last line carries on writing there.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .contentShape(.rect)
                    .onTapGesture(perform: writeAtEnd)
            }
            .coordinateSpace(name: Self.space)
            .overlay(alignment: .topLeading) {
                if let drop {
                    Capsule().fill(Brand.Palette.accent).frame(width: drop.width, height: 2.5).offset(x: drop.x, y: drop.y - 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear { blocks = NoteBlocks.parse(markdown) }
        // The note changed somewhere else (sync, the assistant): take it apart again.
        .onChange(of: markdown) { if markdown != NoteBlocks.markdown(blocks) { blocks = NoteBlocks.parse(markdown) } }
    }

    // MARK: Changing the note

    /// Every edit goes through here, so the note's Markdown is written only when something really changed;
    /// opening a note never rewrites it.
    func change(_ edit: (inout [NoteBlock]) -> Void) {
        var edited = blocks
        edit(&edited)
        edited = NoteBlocks.tidied(edited)
        blocks = edited
        let written = NoteBlocks.markdown(edited)
        if written != markdown { markdown = written }
    }

    /// Changes the block `id`, wherever it is.
    func update(_ id: UUID, _ edit: (inout NoteBlock) -> Void) {
        change { blocks in NoteBlocks.with(id, in: &blocks) { list, index in edit(&list[index]) } }
    }

    func send(_ cursor: NoteBlocks.Cursor?) {
        guard let cursor else { return }
        focusID = cursor.id
        focus = FocusRequest(token: focus.token + 1, location: cursor.location)
    }

    /// What was typed into a block. A mark at the start of a plain line turns it into that kind of block, and pasted
    /// lines become blocks of their own.
    func setText(_ text: String, of id: UUID) {
        var cursor: NoteBlocks.Cursor?
        change { blocks in
            NoteBlocks.with(id, in: &blocks) { list, index in
                let block = list[index]
                if block.kind == .paragraph, let made = NoteBlocks.shortcut(text) {
                    (list[index].kind, list[index].text) = (made.kind, made.text)
                    if made.kind == .divider {
                        let below = NoteBlock(kind: .paragraph)
                        list.insert(below, at: index + 1)
                        cursor = (below.id, 0)
                    } else {
                        cursor = (id, made.text.utf16.count)
                    }
                } else if !block.kind.isMultiline, text.contains("\n") {
                    var pasted = NoteBlocks.parse(text)
                    // The block typed into stays what it was; the rest follow as their own blocks.
                    if pasted[0].kind == .paragraph { (pasted[0].kind, pasted[0].indent) = (block.kind, block.indent) }
                    pasted[0].id = id
                    list.replaceSubrange(index...index, with: pasted)
                    if let last = pasted.last(where: \.kind.holdsText) { cursor = (last.id, last.text.utf16.count) }
                } else {
                    list[index].text = text
                }
            }
        }
        send(cursor)
    }

    /// Return, Backspace, the arrows and Tab, as they apply to blocks. False leaves the key to the text itself.
    func command(_ selector: Selector, in view: NSTextView, of id: UUID) -> Bool {
        guard let (list, index) = NoteBlocks.siblings(of: id, in: blocks) else { return false }
        let (block, range, length) = (list[index], view.selectedRange(), (view.string as NSString).length)
        var cursor: NoteBlocks.Cursor?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            change { NoteBlocks.with(id, in: &$0) { cursor = NoteBlocks.split(&$0, at: $1, location: range.location) } }
        case #selector(NSResponder.deleteBackward(_:)):
            guard range.location == 0, range.length == 0 else { return false }
            change { blocks in
                NoteBlocks.with(id, in: &blocks) { list, index in
                    // Emptied code goes back to being a plain line.
                    if block.kind.isMultiline, block.text.isEmpty {
                        list[index].kind = .paragraph
                        cursor = (id, 0)
                    } else if index == 0 || list[index - 1].kind.holdsText || list[index - 1].kind == .divider {
                        cursor = NoteBlocks.joinBackward(&list, at: index)
                    }
                }
            }
        case #selector(NSResponder.moveUp(_:)):
            guard range.location == 0, let above = list[..<index].last(where: \.kind.holdsText) else { return false }
            cursor = (above.id, above.text.utf16.count)
        case #selector(NSResponder.moveDown(_:)):
            guard range.location == length, let below = list[(index + 1)...].first(where: \.kind.holdsText) else { return false }
            cursor = (below.id, 0)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            guard block.kind.isList else { return !block.kind.isMultiline }
            let step = selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
            update(id) { $0.indent = min(NoteBlocks.deepest, max(0, block.indent + step)) }
            return true
        default:
            return false
        }
        send(cursor)
        return cursor != nil
    }

    func writeAtEnd() {
        if let last = blocks.last, last.kind == .paragraph, last.text.isEmpty { return send((last.id, 0)) }
        insert(NoteBlock(kind: .paragraph), after: nil)
    }

    /// Adds a block under the one given (at the end of the note when nil) and puts the cursor in it.
    func insert(_ block: NoteBlock, after id: UUID?) {
        change { blocks in
            func add(to list: inout [NoteBlock], at index: Int) {
                list.insert(block, at: index)
                // Something that takes no typing is followed by a line that does.
                if !block.kind.holdsText, index + 1 == list.count { list.append(NoteBlock(kind: .paragraph)) }
            }
            if let id, NoteBlocks.with(id, in: &blocks, { add(to: &$0, at: $1 + 1) }) != nil { return }
            add(to: &blocks, at: blocks.count)
        }
        // A new layout is typed into from its first cell.
        send((block.cells.first?.first ?? block).kind.holdsText ? ((block.cells.first?.first ?? block).id, 0) : nil)
    }
}
