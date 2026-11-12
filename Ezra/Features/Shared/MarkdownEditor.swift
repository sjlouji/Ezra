import AppKit
import SwiftUI

/// A notes field that shows its text formatted as it is typed: bold, italic, highlight, code, links, headings and bullets.
/// It is stored as Markdown, but the marks are hidden except around the cursor. ⌘B and ⌘I format the selection.
/// It grows with its text.
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

/// Where the keyboard should go: asked for once per `token`, with the cursor at `location`.
struct FocusRequest: Equatable {
    let token: Int
    let location: Int
}

struct MarkdownTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    var weight = NSFont.Weight.regular
    /// Code: a fixed-width font and no Markdown styling.
    var monospaced = false
    /// Quieter text, for a quote or a ticked checkbox.
    var dimmed = false
    var focus: FocusRequest?
    /// Asked before a key command (Return, Backspace, the arrows, Tab) is carried out; true means it has been dealt with.
    var onCommand: ((Selector, NSTextView) -> Bool)?

    private var look: Look { Look(size: fontSize, weight: weight, monospaced: monospaced, dimmed: dimmed) }

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
        Self.style(view, look)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        let restyle = context.coordinator.parent.look != look
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
            Self.style(view, look)
        } else if restyle {
            Self.style(view, look)
        }
        if let focus, focus != context.coordinator.answered {
            context.coordinator.answered = focus
            context.coordinator.take(focus, in: view)
        }
    }

    /// As wide as offered, as tall as the text needs at that width. The height is worked out from the text alone, not
    /// from the view's own layout: the view is asked about several widths before it is given one, and its layout
    /// follows the width it currently has, which is not the width being asked about.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        guard let storage = nsView.textStorage else { return nil }
        let offered = proposal.width ?? 320
        let width = offered.isFinite ? max(offered, 40) : 10_000
        let line = nsView.layoutManager?.defaultLineHeight(for: look.font) ?? fontSize * 1.2
        let text = storage.length == 0 ? NSAttributedString(string: " ", attributes: [.font: look.font]) : storage
        let needed = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: max(ceil(needed.height), line))
    }

    struct Look: Equatable {
        let size: CGFloat
        let weight: NSFont.Weight
        let monospaced: Bool
        let dimmed: Bool

        var font: NSFont { monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight) }
    }

    /// Restyles the whole text. Notes are short, so this is cheap enough to do on every keystroke.
    static func style(_ view: NSTextView, _ look: Look) {
        guard let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let (base, fontSize) = (look.font, look.size)
        let ink = NSColor(look.dimmed ? Brand.Palette.secondary : Brand.Palette.ink), dim = NSColor(Brand.Palette.secondary).withAlphaComponent(0.7)
        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: ink.withAlphaComponent(look.dimmed ? 1 : 0.88)], range: whole)
        view.typingAttributes = [.font: base, .foregroundColor: ink]
        // Code is shown exactly as typed.
        guard !look.monospaced else { return storage.endEditing() }
        let text = storage.string as NSString
        func each(_ pattern: String, _ apply: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return } // the patterns below are fixed and valid
            regex.matches(in: text as String, range: whole).forEach(apply)
        }
        // The marks that make text bold, a link and so on are not shown: the text simply looks the way it is meant.
        // They appear, dimmed, only around the cursor, so the text there can be changed.
        let cursor = (view as? MarkdownTextView)?.isEditing == true ? view.selectedRange() : nil
        let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
        func mark(_ range: NSRange, of whole: NSRange) {
            let near = cursor.map { $0.location <= NSMaxRange(whole) && NSMaxRange($0) >= whole.location } ?? false
            storage.addAttributes(near ? [.foregroundColor: dim] : hidden, range: range)
        }
        /// Styles group 2 (the content); groups 1 and 3 are the marks around it.
        func wrap(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) {
            each(pattern) { match in
                storage.addAttributes(attributes, range: match.range(at: 2))
                mark(match.range(at: 1), of: match.range)
                mark(match.range(at: 3), of: match.range)
            }
        }
        wrap(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#, [.font: NSFont.boldSystemFont(ofSize: fontSize)])
        wrap(#"(?<![\*\w])(\*)(?=[^\s\*])(.+?)(?<=[^\s\*])(\*)(?!\*)"#, [.font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)])
        wrap(#"(::)(?=\S)(.+?)(?<=\S)(::)"#, [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)])
        wrap(#"(`)([^`\n]+)(`)"#, [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular), .backgroundColor: NSColor(Brand.Palette.field)])
        wrap(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#, [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        let link: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(Brand.Palette.accent)]
        wrap(#"(\[\[)([^\[\]\n]+)(\]\])"#, link)
        wrap(#"(?<!\[)(\[)([^\[\]\n]+)(\]\([^)\n]+\))"#, link.merging([.underlineStyle: NSUnderlineStyle.single.rawValue]) { first, _ in first })
        each(#"^(#{1,3} )(.+)$"#) { match in
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: fontSize + 2), range: match.range)
            mark(match.range(at: 1), of: match.range)
        }
        each(#"^\s*([-*+•]|\d+\.) "#) { match in
            storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
        }
        storage.endEditing()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextField
        /// The focus request already acted on, so it is not acted on again at every redraw.
        var answered: FocusRequest?
        private var isStyling = false
        init(_ parent: MarkdownTextField) { self.parent = parent }

        /// Gives `view` the keyboard with the cursor where asked. A view that has only just been made is not in its
        /// window yet, and the view it replaces may still give the keyboard up after it, so this waits and checks again.
        func take(_ focus: FocusRequest, in view: NSTextView, tries: Int = 12) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 12 ? 0 : 0.03)) { [weak self, weak view] in
                // A newer request has gone to another block since.
                guard let self, let view, self.answered == focus else { return }
                if let window = view.window, window.firstResponder !== view {
                    window.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: min(focus.location, (view.string as NSString).length), length: 0))
                } else if view.window != nil, tries == 12 {
                    view.setSelectedRange(NSRange(location: min(focus.location, (view.string as NSString).length), length: 0))
                }
                if tries > 0, view.window == nil || tries > 9 { self.take(focus, in: view, tries: tries - 1) }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.onCommand?(selector, textView) ?? false
        }

        /// The marks around the cursor show and the others hide, so the styling follows the cursor.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !isStyling else { return }
            restyle(view)
        }

        func restyle(_ view: NSTextView) {
            isStyling = true
            defer { isStyling = false }
            MarkdownTextField.style(view, parent.look)
            view.invalidateIntrinsicContentSize()
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selection = view.selectedRanges
            MarkdownTextField.style(view, parent.look)
            view.selectedRanges = selection
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
    }
}

final class MarkdownTextView: NSTextView {
    /// True while the keyboard is in this view; only then are the marks around the cursor shown.
    private(set) var isEditing = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { setEditing(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setEditing(false) }
        return resigned
    }

    private func setEditing(_ editing: Bool) {
        isEditing = editing
        (delegate as? MarkdownTextField.Coordinator)?.restyle(self)
    }

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
