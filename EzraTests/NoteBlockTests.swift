import Foundation
import Testing
@testable import Ezra

/// A note's Markdown taken apart into blocks and put back, and what the keyboard does to the blocks.
struct NoteBlockTests {
    private func shape(_ blocks: [NoteBlock]) -> [String] {
        blocks.map { "\($0.kind)|\($0.indent)|\($0.text)" }
    }

    @Test func markdownIsReadIntoBlocks() {
        let source = """
            Title
            =====
            Plain *text*.

            ## Section ##
            - one
              - nested
            * [x] done
            1. first
            2. second
            > quoted
            ***
            ~~~python
            print(1)

            print(2)
            ~~~
            | a | b |
            |---|---|
            | 1 | 2 |
            last
            """
        let blocks = NoteBlocks.parse(source)
        #expect(shape(blocks) == [
            "heading(1)|0|Title", "paragraph|0|Plain *text*.", "paragraph|0|", "heading(2)|0|Section",
            "bullet|0|one", "bullet|1|nested", "checkbox(true)|0|done", "numbered|0|first", "numbered|0|second",
            "quote|0|quoted", "divider|0|", "code(\"python\")|0|print(1)\n\nprint(2)", "table|0|| a | b |\n|---|---|\n| 1 | 2 |", "paragraph|0|last",
        ])
        #expect(NoteBlocks.table(blocks[12].text)?.rows == [["1", "2"]])
    }

    @Test func blocksAreWrittenAsMarkdownThatReadsBackTheSame() {
        let source = "# Plan\nIntro\n\n- a\n  - b\n- [ ] c\n- [x] d\n1. one\n2. two\n> why\n\n---\n```swift\nlet x = 1\n```\n| k | v |\n|---|---|\n| a | 1 |\nend"
        let blocks = NoteBlocks.parse(source)
        // What the app itself writes comes back unchanged, so opening a note never rewrites it.
        #expect(NoteBlocks.markdown(blocks) == source)
        #expect(shape(NoteBlocks.parse(NoteBlocks.markdown(blocks))) == shape(blocks))
        // A note written before the editor existed reads the same as it did.
        let old = "# Goal\nPick **2 winter tacos**.\n\n- Squash taco\n\n## To do\n- [x] Order squash\n- [ ] Print the menu"
        #expect(NoteBlocks.markdown(NoteBlocks.parse(old)) == old)
    }

    @Test func numbersFollowTheListAndADividerUnderTextStaysADivider() {
        var blocks = NoteBlocks.parse("1. a\n1. b\n   - x\n1. c\ntext\n7. d")
        #expect(NoteBlocks.markdown(blocks) == "1. a\n2. b\n  - x\n3. c\ntext\n1. d")
        blocks = [NoteBlock(kind: .paragraph, text: "Above"), NoteBlock(kind: .divider), NoteBlock(kind: .paragraph, text: "Below")]
        let written = NoteBlocks.markdown(blocks)
        #expect(written == "Above\n***\nBelow")
        #expect(shape(NoteBlocks.parse(written)) == shape(blocks))
    }

    @Test func returnSplitsABlockAndEndsAnEmptyListItem() {
        var blocks = NoteBlocks.parse("- [x] buy milk\nHello world")
        // In a checklist, Return starts the next, unticked item with the text after the cursor.
        var cursor = NoteBlocks.split(&blocks, at: 0, location: 4)
        #expect(shape(blocks) == ["checkbox(true)|0|buy ", "checkbox(false)|0|milk", "paragraph|0|Hello world"])
        #expect(cursor?.id == blocks[1].id && cursor?.location == 0)
        // Return on an empty item leaves the list.
        blocks[1].text = ""
        cursor = NoteBlocks.split(&blocks, at: 1, location: 0)
        #expect(shape(blocks)[1] == "paragraph|0|" && cursor?.id == blocks[1].id)
        // A heading is followed by plain text.
        blocks = NoteBlocks.parse("# Title")
        _ = NoteBlocks.split(&blocks, at: 0, location: 5)
        #expect(shape(blocks) == ["heading(1)|0|Title", "paragraph|0|"])
        // Code keeps its Return.
        blocks = NoteBlocks.parse("```\nx\n```")
        #expect(NoteBlocks.split(&blocks, at: 0, location: 1) == nil)
    }

    @Test func backspaceAtTheStartUnstylesThenJoins() {
        var blocks = NoteBlocks.parse("Hello\n## world\n---\nafter")
        // A heading first becomes plain text, then joins the line above, with the cursor at the seam.
        var cursor = NoteBlocks.joinBackward(&blocks, at: 1)
        #expect(shape(blocks)[1] == "paragraph|0|world" && cursor?.location == 0)
        cursor = NoteBlocks.joinBackward(&blocks, at: 1)
        #expect(shape(blocks) == ["paragraph|0|Helloworld", "divider|0|", "paragraph|0|after"])
        #expect(cursor?.id == blocks[0].id && cursor?.location == 5)
        // Backspace under a divider removes the divider.
        _ = NoteBlocks.joinBackward(&blocks, at: 2)
        #expect(shape(blocks) == ["paragraph|0|Helloworld", "paragraph|0|after"])
        // The first block has nothing above to join.
        #expect(NoteBlocks.joinBackward(&blocks, at: 0) == nil)
        // A nested item steps out one level at a time.
        blocks = NoteBlocks.parse("- a\n  - b")
        _ = NoteBlocks.joinBackward(&blocks, at: 1)
        #expect(shape(blocks)[1] == "bullet|0|b")
    }

    @Test func typingAMarkAtTheStartOfALineChangesTheBlock() {
        func made(_ text: String) -> String? { NoteBlocks.shortcut(text).map { "\($0.kind)|\($0.text)" } }
        #expect(made("# ") == "heading(1)|" && made("### Deep") == "heading(3)|Deep")
        #expect(made("[] ") == "checkbox(false)|" && made("- [ ] call") == "checkbox(false)|call")
        #expect(made("1. ") == "numbered|" && made("> ") == "quote|" && made("---") == "divider|" && made("```swift") == "code(\"swift\")|")
        // "- " waits for a letter, so a checkbox can still be typed; then it is a bullet.
        #expect(made("- ") == nil && made("- [") == nil && made("- a") == "bullet|a")
        #expect(made("plain") == nil && made("#hashtag") == nil && made("2024 was") == nil)
    }

    @Test func layoutsAreStoredAsCommentsAndReadBackWithTheirCells() {
        let source = "Intro\n<!-- layout 1:2 -->\n## Left\n- a\n<!-- cell -->\nRight text\n1. one\n2. two\n<!-- cell -->\nthird cell\n<!-- /layout -->\nOutro"
        let blocks = NoteBlocks.parse(source)
        #expect(shape(blocks) == ["paragraph|0|Intro", "layout([1, 2])|0|", "paragraph|0|Outro"])
        #expect(blocks[1].cells.map(shape) == [["heading(2)|0|Left", "bullet|0|a"], ["paragraph|0|Right text", "numbered|0|one", "numbered|0|two"], ["paragraph|0|third cell"]])
        #expect(NoteBlocks.markdown(blocks) == source)
        // Numbers count inside each cell on their own.
        let numbers = NoteBlocks.numbers(in: blocks)
        #expect(numbers[blocks[1].cells[1][2].id] == 2)
        // A layout inside a cell keeps to itself; one never closed takes the rest of the note.
        let nested = NoteBlocks.parse("<!-- layout 1:1 -->\na\n<!-- layout 1:1 -->\nb\n<!-- cell -->\nc\n<!-- /layout -->\n<!-- cell -->\nd\n<!-- /layout -->")
        #expect(nested.count == 1 && nested[0].cells.count == 2 && nested[0].cells[0][1].cells.count == 2)
        #expect(NoteBlocks.parse("<!-- layout -->\nx\n<!-- cell -->\ny")[0].cells.map(shape) == [["paragraph|0|x"], ["paragraph|0|y"]])
    }

    @Test func blocksAreFoundEditedAndMovedInsideCells() {
        var blocks = NoteBlocks.parse("top\n<!-- layout 1:1 -->\nleft\n<!-- cell -->\nright\n<!-- /layout -->\nbottom")
        let (layout, left, right, top) = (blocks[1].id, blocks[1].cells[0][0].id, blocks[1].cells[1][0].id, blocks[0].id)
        // Return inside a cell splits within that cell.
        let cursor = NoteBlocks.with(left, in: &blocks) { NoteBlocks.split(&$0, at: $1, location: 2) }
        #expect(blocks[1].cells[0].map(\.text) == ["le", "ft"] && cursor??.location == 0)
        #expect(NoteBlocks.siblings(of: right, in: blocks)?.index == 0 && NoteBlocks.with(UUID(), in: &blocks) { _, _ in 1 } == nil)

        // A block moves from the note into a cell, between cells, and back out.
        NoteBlocks.move(top, to: .init(layout: layout, index: 1), at: 1, in: &blocks)
        #expect(blocks.map(\.text) == ["", "bottom"] && blocks[0].cells[1].map(\.text) == ["right", "top"])
        NoteBlocks.move(right, to: .init(layout: layout, index: 0), at: 0, in: &blocks)
        #expect(blocks[0].cells.map { $0.map(\.text) } == [["right", "le", "ft"], ["top"]])
        NoteBlocks.move(top, to: nil, at: 0, in: &blocks)
        #expect(blocks.map(\.text) == ["top", "", "bottom"] && blocks[1].cells[1].isEmpty)
        // An emptied cell gets a line to type in again; a layout is never put inside itself.
        blocks = NoteBlocks.tidied(blocks)
        #expect(blocks[1].cells[1].map(\.kind) == [.paragraph])
        NoteBlocks.move(layout, to: .init(layout: layout, index: 0), at: 0, in: &blocks)
        #expect(blocks.count == 3 && blocks[1].id == layout)
        #expect(NoteBlocks.tidied([]).count == 1 && NoteBlocks.layout([1, 1, 1], cells: 6).cells.count == 6)
    }
}
