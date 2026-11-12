import Foundation

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(String)
    case checkbox(done: Bool, text: String)
    case paragraph(String)
    case blank
}

/// The small Markdown subset a note page renders: headings, bullets, checkboxes and paragraphs, one block per line.
enum NoteMarkdown {
    static func blocks(_ source: String) -> [MarkdownBlock] {
        source.components(separatedBy: "\n").map(block)
    }

    static func block(_ line: String) -> MarkdownBlock {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .blank }
        for (marker, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where text.hasPrefix(marker) {
            return .checkbox(done: done, text: String(text.dropFirst(marker.count)))
        }
        for marker in ["- ", "* "] where text.hasPrefix(marker) {
            return .bullet(String(text.dropFirst(marker.count)))
        }
        for level in (1...3).reversed() {
            let marker = String(repeating: "#", count: level) + " "
            if text.hasPrefix(marker) {
                return .heading(level: level, text: String(text.dropFirst(marker.count)))
            }
        }
        return .paragraph(text)
    }

    /// `source` with the checkbox on line `index` flipped; unchanged when that line is not a checkbox.
    static func togglingCheckbox(atLine index: Int, in source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(index), case .checkbox(let done, _) = block(lines[index]) else { return source }
        let (from, to) = done ? ("[x]", "[ ]") : ("[ ]", "[x]")
        guard let range = lines[index].range(of: from, options: .caseInsensitive) else { return source }
        lines[index].replaceSubrange(range, with: to)
        return lines.joined(separator: "\n")
    }
}

extension NoteMarkdown {
    /// Bold, italic, code and links. Text that is not valid Markdown is shown exactly as typed.
    static func inline(_ text: String) -> AttributedString {
        do {
            return try AttributedString(markdown: NoteLinks.markdown(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            Log.store.debug("Inline Markdown not parsed, showing source: \(String(describing: error), privacy: .public)")
            return AttributedString(text)
        }
    }
}

/// A piece of an assistant reply: a line of note-style Markdown, a table, or a block of code.
enum ReplyBlock: Equatable {
    case line(MarkdownBlock)
    case table(header: [String], rows: [[String]])
    case code(String)
}

/// What a chat reply renders: everything a note does, plus Markdown tables and fenced code, which span lines.
enum ReplyMarkdown {
    static func blocks(_ source: String) -> [ReplyBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [ReplyBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                // Fenced code runs to the closing fence, or to the end when the model forgot to close it.
                let end = lines[(index + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") } ?? lines.count
                blocks.append(.code(lines[(index + 1)..<end].joined(separator: "\n")))
                index = end + 1
            } else if isRow(line), index + 1 < lines.count, isSeparator(lines[index + 1]) {
                var rows: [[String]] = []
                var next = index + 2
                while next < lines.count, isRow(lines[next].trimmingCharacters(in: .whitespaces)) {
                    rows.append(cells(lines[next]))
                    next += 1
                }
                blocks.append(.table(header: cells(line), rows: rows))
                index = next
            } else {
                blocks.append(.line(NoteMarkdown.block(line)))
                index += 1
            }
        }
        return blocks
    }

    private static func isRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.dropFirst().contains("|")
    }

    /// The line under a table's header: only pipes, dashes, colons and spaces.
    private static func isSeparator(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return isRow(text) && text.contains("-") && text.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
