import AppKit
import SwiftUI

/// A notes field that shows Markdown as it is typed: **bold**, *italic*, ::highlight::, # headings, and bullets.
/// The marks stay visible, dimmed. ⌘B and ⌘I wrap the selection. It grows with its text.
struct MarkdownEditor: View {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 13.5

    var body: some View {
        MarkdownTextField(text: $text, fontSize: fontSize)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Brand.Palette.secondary.opacity(0.7))
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct MarkdownTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.drawsBackground = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.string = text
        Self.style(view, fontSize: fontSize)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        context.coordinator.parent = self
        guard view.string != text else { return }
        view.string = text
        Self.style(view, fontSize: fontSize)
    }

    /// As wide as offered, as tall as the text needs.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let width = max(proposal.width ?? 320, 40)
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: .systemFont(ofSize: fontSize))
        return CGSize(width: width, height: max(ceil(layout.usedRect(for: container).height), lineHeight))
    }

    /// Restyles the whole text. Notes are short, so this is cheap enough to do on every keystroke.
    static func style(_ view: NSTextView, fontSize: CGFloat) {
        guard let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let base = NSFont.systemFont(ofSize: fontSize)
        let ink = NSColor(Brand.Palette.ink), dim = NSColor(Brand.Palette.secondary).withAlphaComponent(0.7)
        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: ink.withAlphaComponent(0.88)], range: whole)
        let text = storage.string as NSString
        func each(_ pattern: String, _ apply: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return } // the patterns below are fixed and valid
            regex.matches(in: text as String, range: whole).forEach(apply)
        }
        /// Styles group 2 (the content) and dims groups 1 and 3 (the marks around it).
        func wrap(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) {
            each(pattern) { match in
                storage.addAttributes(attributes, range: match.range(at: 2))
                storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
                storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 3))
            }
        }
        wrap(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#, [.font: NSFont.boldSystemFont(ofSize: fontSize)])
        wrap(#"(?<![\*\w])(\*)(?=[^\s\*])(.+?)(?<=[^\s\*])(\*)(?!\*)"#, [.font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)])
        wrap(#"(::)(?=\S)(.+?)(?<=\S)(::)"#, [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)])
        each(#"^(#{1,3} )(.+)$"#) { match in
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: fontSize + 2), range: match.range)
            storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
        }
        each(#"^\s*([-*+•]|\d+\.) "#) { match in
            storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
        }
        storage.endEditing()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextField
        init(_ parent: MarkdownTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selection = view.selectedRanges
            MarkdownTextField.style(view, fontSize: parent.fontSize)
            view.selectedRanges = selection
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
    }
}

final class MarkdownTextView: NSTextView {
    /// ⌘B and ⌘I put Markdown marks around the selection.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": surroundSelection(with: "**")
        case "i": surroundSelection(with: "*")
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func surroundSelection(with mark: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        guard shouldChangeText(in: range, replacementString: mark + selected + mark) else { return }
        replaceCharacters(in: range, with: mark + selected + mark)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + mark.count, length: range.length))
    }
}
