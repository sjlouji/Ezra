import Foundation

/// What the keyboard does to the blocks. Each returns the block to put the cursor in and where, or nil when it did nothing.
extension NoteBlocks {
    typealias Cursor = (id: UUID, location: Int)

    /// Return: the text after the cursor starts a new block below. An empty list item ends its list instead.
    static func split(_ blocks: inout [NoteBlock], at index: Int, location: Int) -> Cursor? {
        let block = blocks[index]
        guard !block.kind.isMultiline, block.kind != .divider else { return nil }
        if block.kind.isList || block.kind == .quote, block.text.isEmpty {
            if block.indent > 0 { blocks[index].indent -= 1 } else { blocks[index].kind = .paragraph }
            return (block.id, 0)
        }
        let cut = block.text.utf16.index(block.text.utf16.startIndex, offsetBy: min(location, block.text.utf16.count))
        let (head, tail) = (String(block.text[..<cut]), String(block.text[cut...]))
        // A list goes on with another item; anything else is followed by plain text.
        let kind: NoteBlock.Kind = switch block.kind {
        case .checkbox: .checkbox(false)
        case .bullet, .numbered, .quote: block.kind
        default: .paragraph
        }
        blocks[index].text = head
        let new = NoteBlock(kind: kind, text: tail, indent: block.kind.isList ? block.indent : 0)
        blocks.insert(new, at: index + 1)
        return (new.id, 0)
    }

    /// Backspace at the start of a block: a styled block becomes plain text; plain text joins the block above.
    static func joinBackward(_ blocks: inout [NoteBlock], at index: Int) -> Cursor? {
        let block = blocks[index]
        guard !block.kind.isMultiline else { return nil }
        if block.kind != .paragraph {
            if block.kind.isList, block.indent > 0 { blocks[index].indent -= 1 } else { blocks[index].kind = .paragraph }
            return (block.id, 0)
        }
        guard index > 0 else { return nil }
        let above = blocks[index - 1]
        if above.kind == .divider {
            blocks.remove(at: index - 1)
            return (block.id, 0)
        }
        // Code and tables are not merged into; an empty line under one is simply removed.
        if above.kind.isMultiline {
            guard block.text.isEmpty else { return nil }
            blocks.remove(at: index)
            return (above.id, above.text.utf16.count)
        }
        blocks[index - 1].text += block.text
        blocks.remove(at: index)
        return (above.id, above.text.utf16.count)
    }

    /// What typing at the start of a plain line turns it into: "# " a heading, "- " a bullet, "[] " a checkbox, and so on.
    /// Returns nil when `text` starts with no such mark.
    static func shortcut(_ text: String) -> NoteBlock? {
        for (mark, kind) in [("### ", NoteBlock.Kind.heading(3)), ("## ", .heading(2)), ("# ", .heading(1)), ("[] ", .checkbox(false)), ("[ ] ", .checkbox(false)),
                             ("- [ ] ", .checkbox(false)), ("> ", .quote)] where text.hasPrefix(mark) {
            return NoteBlock(kind: kind, text: String(text.dropFirst(mark.count)))
        }
        if text.hasPrefix("```") { return NoteBlock(kind: .code(String(text.dropFirst(3)))) }
        if text == "---" || text == "***" { return NoteBlock(kind: .divider) }
        // "- " alone waits for one more character, so "- [ ] " can still be typed.
        if let item = listItem(text), item.kind != .bullet || !item.text.isEmpty && !item.text.hasPrefix("[") {
            return NoteBlock(kind: item.kind, text: item.text)
        }
        return nil
    }
}

/// Finding and moving blocks wherever they are: at the top of the note or inside a layout's cell.
extension NoteBlocks {
    /// A cell of a layout.
    struct CellRef: Hashable {
        let layout: UUID
        let index: Int
    }

    /// Runs `edit` on the run of blocks that holds `id` (the note's own, or a cell's), with the block's place in it.
    /// Nil when there is no such block.
    @discardableResult
    static func with<Result>(_ id: UUID, in blocks: inout [NoteBlock], _ edit: (inout [NoteBlock], Int) -> Result) -> Result? {
        if let index = blocks.firstIndex(where: { $0.id == id }) { return edit(&blocks, index) }
        for layout in blocks.indices {
            for cell in blocks[layout].cells.indices {
                if let result = with(id, in: &blocks[layout].cells[cell], edit) { return result }
            }
        }
        return nil
    }

    /// The run of blocks `id` is in, and its place there.
    static func siblings(of id: UUID, in blocks: [NoteBlock]) -> (list: [NoteBlock], index: Int)? {
        var copy = blocks
        return with(id, in: &copy) { ($0, $1) }
    }

    /// Takes `id` out of the note and puts it at `index` of a cell, or of the note itself when `cell` is nil.
    /// A layout is not put inside its own cells.
    static func move(_ id: UUID, to cell: CellRef?, at index: Int, in blocks: inout [NoteBlock]) {
        guard let moving = siblings(of: id, in: blocks).map({ $0.list[$0.index] }) else { return }
        if let cell, moving.id == cell.layout || siblings(of: cell.layout, in: moving.cells.flatMap { $0 }) != nil { return }
        with(id, in: &blocks) { list, at in _ = list.remove(at: at) }
        if let cell {
            with(cell.layout, in: &blocks) { list, at in
                guard list[at].cells.indices.contains(cell.index) else { return list.insert(moving, at: min(at + 1, list.count)) }
                list[at].cells[cell.index].insert(moving, at: min(index, list[at].cells[cell.index].count))
            }
        } else {
            blocks.insert(moving, at: min(index, blocks.count))
        }
    }

    /// Every cell keeps at least an empty line to type in, a layout with no cells goes, and the note is never empty.
    static func tidied(_ blocks: [NoteBlock], isCell: Bool = false) -> [NoteBlock] {
        var tidy = blocks.compactMap { block -> NoteBlock? in
            guard block.kind.isLayout else { return block }
            guard !block.cells.isEmpty else { return nil }
            var block = block
            block.cells = block.cells.map { tidied($0, isCell: true) }
            return block
        }
        if tidy.isEmpty { tidy = [NoteBlock(kind: .paragraph)] }
        return tidy
    }

    /// A copy with identities of its own, all the way down, so the copy and the original can be told apart.
    static func copy(of block: NoteBlock) -> NoteBlock {
        NoteBlock(kind: block.kind, text: block.text, indent: block.indent, cells: block.cells.map { $0.map(copy) })
    }

    /// A new layout with `cells` empty cells in columns of the given relative widths.
    static func layout(_ widths: [Int], cells: Int) -> NoteBlock {
        NoteBlock(kind: .layout(widths), cells: (0..<cells).map { _ in [NoteBlock(kind: .paragraph)] })
    }
}
