import Foundation

/// One piece of a note as the editor shows it. A note is stored as Markdown; this is that Markdown taken apart.
struct NoteBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet
        case numbered
        case checkbox(Bool)
        case quote
        /// Fenced code, with the language named on the fence. Its text spans lines.
        case code(String)
        case divider
        /// A pipe table, kept as its Markdown lines.
        case table
        /// Cells side by side: one relative width per column. More cells than columns wrap into further rows, a grid.
        case layout([Int])

        var isList: Bool {
            switch self {
            case .bullet, .numbered, .checkbox: true
            default: false
            }
        }
        /// Blocks whose text is several lines: Return adds a line instead of starting a new block.
        var isMultiline: Bool {
            switch self {
            case .code, .table: true
            default: false
            }
        }
        /// Blocks with a line of text the cursor can be put in.
        var holdsText: Bool {
            switch self {
            case .divider, .table, .layout: false
            default: true
            }
        }
        var isLayout: Bool {
            if case .layout = self { true } else { false }
        }
    }

    var id = UUID()
    var kind: Kind
    var text = ""
    /// How deep a list item is nested, 0 to 4.
    var indent = 0
    /// A layout's cells, each a run of blocks of its own. Empty for every other kind.
    var cells: [[NoteBlock]] = []
}

/// Markdown to blocks and back. What the editor writes is ordinary Markdown any other app can read.
enum NoteBlocks {
    static let deepest = 4
    private static let layoutOpen = "<!-- layout", layoutCell = "<!-- cell -->", layoutClose = "<!-- /layout -->"

    static func parse(_ markdown: String) -> [NoteBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [NoteBlock] = []
        // The indent of the first item of the list being read; deeper items are nested relative to it.
        var listBase: Int?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let text = line.trimmingCharacters(in: .whitespaces)
            let spaces = line.prefix { $0 == " " }.count
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : nil
            defer { index += 1 }

            if text.hasPrefix(layoutOpen), text.hasSuffix("-->") {
                // A layout runs to its own closing line; layouts inside it are counted so theirs is not mistaken for it.
                var (depth, end, cells, cell) = (1, index + 1, [[String]](), [String]())
                while end < lines.count {
                    let inner = lines[end].trimmingCharacters(in: .whitespaces)
                    if inner.hasPrefix(layoutOpen), inner.hasSuffix("-->") { depth += 1 }
                    if inner == layoutClose { depth -= 1 }
                    if depth == 0 { break }
                    if depth == 1, inner == layoutCell { cells.append(cell); cell = [] } else { cell.append(lines[end]) }
                    end += 1
                }
                cells.append(cell)
                let widths = text.dropFirst(layoutOpen.count).dropLast(3).split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
                blocks.append(NoteBlock(kind: .layout(widths.isEmpty ? [1, 1] : widths), cells: cells.map { parse($0.joined(separator: "\n")) }))
                (index, listBase) = (end, nil)
            } else if let fence = ["```", "~~~"].first(where: text.hasPrefix) {
                // Code runs to the closing fence, or to the end when it was never closed.
                let end = lines[(index + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(fence) } ?? lines.count
                blocks.append(NoteBlock(kind: .code(String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)), text: lines[(index + 1)..<end].joined(separator: "\n")))
                (index, listBase) = (end, nil)
            } else if isTableRow(text), let next, isTableRule(next) {
                var end = index + 2
                while end < lines.count, isTableRow(lines[end].trimmingCharacters(in: .whitespaces)) { end += 1 }
                blocks.append(NoteBlock(kind: .table, text: lines[index..<end].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")))
                (index, listBase) = (end - 1, nil)
            } else if text.isEmpty {
                // A blank line does not end a list.
                blocks.append(NoteBlock(kind: .paragraph))
            } else if let item = listItem(text) {
                let base = listBase ?? spaces
                listBase = base
                blocks.append(NoteBlock(kind: item.kind, text: item.text, indent: min(deepest, max(0, spaces - base) / 2)))
            } else {
                listBase = nil
                if isRule(text) {
                    blocks.append(NoteBlock(kind: .divider))
                } else if let level = (1...3).reversed().first(where: { text.hasPrefix(String(repeating: "#", count: $0) + " ") }) {
                    // "### Title ###" is the same heading as "### Title".
                    let title = text.dropFirst(level + 1).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    blocks.append(NoteBlock(kind: .heading(level), text: title))
                } else if text.hasPrefix(">") {
                    blocks.append(NoteBlock(kind: .quote, text: String(text.dropFirst()).trimmingCharacters(in: .whitespaces)))
                } else if let next, next.count >= 2, next.allSatisfy({ $0 == "=" }) || next.allSatisfy({ $0 == "-" }) {
                    // A line underlined with === or --- is a heading.
                    blocks.append(NoteBlock(kind: .heading(next.hasPrefix("=") ? 1 : 2), text: text))
                    index += 1
                } else {
                    blocks.append(NoteBlock(kind: .paragraph, text: text))
                }
            }
        }
        return blocks
    }

    static func markdown(_ blocks: [NoteBlock]) -> String {
        let numbers = numbers(in: blocks)
        return blocks.enumerated().map { index, block in
            let pad = String(repeating: "  ", count: block.indent)
            switch block.kind {
            case .paragraph: return block.text
            case .heading(let level): return String(repeating: "#", count: level) + " " + block.text
            case .bullet: return pad + "- " + block.text
            case .numbered: return pad + "\(numbers[block.id] ?? 1). " + block.text
            case .checkbox(let done): return pad + (done ? "- [x] " : "- [ ] ") + block.text
            case .quote: return "> " + block.text
            case .code(let language): return "```\(language)\n\(block.text)\n```"
            case .table: return block.text
            // Written as comments, which other apps that read Markdown do not show: there the cells simply follow one another.
            case .layout(let widths):
                return "\(layoutOpen) \(widths.map(String.init).joined(separator: ":")) -->\n"
                    + block.cells.map(markdown).joined(separator: "\n\(layoutCell)\n") + "\n\(layoutClose)"
            // Straight under a line of text, "---" would turn that line into a heading.
            case .divider: return index > 0 && blocks[index - 1].kind == .paragraph && !blocks[index - 1].text.isEmpty ? "***" : "---"
            }
        }
        .joined(separator: "\n")
    }

    /// The number each numbered item shows: counted along its run, per depth; a run ends where something else sits at its depth or above.
    static func numbers(in blocks: [NoteBlock]) -> [UUID: Int] {
        var counters = [Int](repeating: 0, count: deepest + 1)
        var numbers: [UUID: Int] = [:]
        for block in blocks {
            // Each cell of a layout counts for itself.
            for cell in block.cells { numbers.merge(self.numbers(in: cell)) { first, _ in first } }
            // An empty line between items does not restart the count.
            if block.kind == .paragraph, block.text.isEmpty { continue }
            let depth = block.kind.isList ? block.indent : 0
            for deeper in (depth + 1)...(deepest + 1) where deeper <= deepest { counters[deeper] = 0 }
            if block.kind == .numbered {
                counters[depth] += 1
                numbers[block.id] = counters[depth]
            } else {
                counters[depth] = 0
            }
        }
        return numbers
    }

    /// The header and rows of a table block; nil when its text is not a table any more.
    static func table(_ text: String) -> (header: [String], rows: [[String]])? {
        if case .table(let header, let rows) = ReplyMarkdown.blocks(text).first { return (header, rows) }
        return nil
    }

    /// A table as Markdown. A "|" inside a cell would split it, so it is written as a similar-looking bar.
    static func tableMarkdown(header: [String], rows: [[String]]) -> String {
        func line(_ cells: [String]) -> String {
            "| " + header.indices.map { $0 < cells.count ? cells[$0].replacingOccurrences(of: "|", with: "¦") : "" }.joined(separator: " | ") + " |"
        }
        return ([line(header), "|" + header.map { _ in "---" }.joined(separator: "|") + "|"] + rows.map(line)).joined(separator: "\n")
    }

    static func listItem(_ text: String) -> (kind: NoteBlock.Kind, text: String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] {
            for bullet in ["- ", "* ", "+ "] where text.hasPrefix(bullet + marker) {
                return (.checkbox(done), String(text.dropFirst(bullet.count + marker.count)))
            }
        }
        for bullet in ["- ", "* ", "+ "] where text.hasPrefix(bullet) { return (.bullet, String(text.dropFirst(2))) }
        let digits = text.prefix { $0.isNumber }
        let rest = text.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 4, rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (.numbered, String(rest.dropFirst(2))) }
        return nil
    }

    /// Three or more of -, * or _ alone on a line.
    private static func isRule(_ text: String) -> Bool {
        let marks = text.filter { $0 != " " }
        return marks.count >= 3 && ["-", "*", "_"].contains { mark in marks.allSatisfy { String($0) == mark } }
    }

    private static func isTableRow(_ text: String) -> Bool { text.hasPrefix("|") && text.dropFirst().contains("|") }

    private static func isTableRule(_ text: String) -> Bool {
        isTableRow(text) && text.contains("-") && text.allSatisfy { "|-: ".contains($0) }
    }
}
