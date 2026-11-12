import SwiftUI

/// How each kind of block looks, and the handle beside it.
extension BlockEditor {
    /// The kinds a block can be made or turned into, as the menus name them.
    static let kinds: [(name: String, symbol: String, kind: NoteBlock.Kind)] = [
        ("Text", "text.alignleft", .paragraph), ("Heading 1", "textformat.size.larger", .heading(1)),
        ("Heading 2", "textformat.size", .heading(2)), ("Heading 3", "textformat.size.smaller", .heading(3)),
        ("Bulleted List", "list.bullet", .bullet), ("Numbered List", "list.number", .numbered),
        ("Checkbox", "checkmark.square", .checkbox(false)), ("Quote", "text.quote", .quote),
        ("Code", "chevron.left.forwardslash.chevron.right", .code("")), ("Table", "tablecells", .table), ("Divider", "minus", .divider),
    ]
    static let emptyTable = "| Column | Column |\n|---|---|\n|  |  |"

    /// One block with its handle. A layout's cells hold rows of their own, so this is called again from inside itself.
    func row(_ block: NoteBlock, numbers: [UUID: Int], inCell: Bool) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 0) {
                handle(for: block, inCell: inCell)
                    .frame(width: inCell ? 32 : Self.gutter, alignment: .trailing)
                    .opacity(hovered.contains(block.id) || drag?.id == block.id || menuFor == block.id ? 1 : 0)
                Color.clear.frame(width: CGFloat(block.indent) * 22, height: 1)
                marker(for: block, number: numbers[block.id])
                if case .layout(let widths) = block.kind {
                    layout(block, widths: widths, numbers: numbers)
                } else {
                    content(of: block)
                }
            }
            .padding(.vertical, padding(for: block.kind))
            .contentShape(.rect)
            .onHover { inside in
                if inside { hovered.insert(block.id) } else { hovered.remove(block.id) }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[block.id] = $0 }
            .opacity(drag?.id == block.id ? 0.35 : 1)
        )
    }

    private func padding(for kind: NoteBlock.Kind) -> CGFloat {
        switch kind {
        case .heading(1): 8
        case .heading: 6
        case .code, .table, .layout: 5
        default: 2.5
        }
    }

    /// The plus that adds a block below, and the grip that drags this one or, clicked, shows what can be done with it.
    private func handle(for block: NoteBlock, inCell: Bool) -> some View {
        HStack(spacing: 1) {
            Menu {
                ForEach(Self.kinds, id: \.name) { item in
                    Button(item.name, systemImage: item.symbol) {
                        insert(NoteBlock(kind: item.kind, text: item.kind == .table ? Self.emptyTable : ""), after: block.id)
                    }
                }
                // Layouts sit in the note itself, not inside one another.
                if !inCell {
                    Divider()
                    Menu("Layout") {
                        ForEach(Self.layouts, id: \.name) { preset in
                            Button(preset.name, systemImage: preset.symbol) { insert(NoteBlocks.layout(preset.widths, cells: preset.cells), after: block.id) }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus").accessibilityLabel("Add a block below")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a block below")
            Image(systemName: "square.grid.2x2")
                .frame(width: 16, height: 20)
                .contentShape(.rect)
                .pointerStyle(.grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                        .onChanged { drag = (block.id, $0.location) }
                        .onEnded { _ in endDrag() }
                )
                .onTapGesture { menuFor = block.id }
                .popover(isPresented: Binding(get: { menuFor == block.id }, set: { if !$0 { menuFor = nil } }), arrowEdge: .leading) {
                    if case .layout(let widths) = block.kind { layoutActions(for: block, widths: widths) } else { actions(for: block) }
                }
                .help("Drag to move. Click for more.")
                .accessibilityLabel("Move or change this block")
        }
        .font(.system(size: 12))
        .foregroundStyle(Brand.Palette.secondary)
        .padding(.trailing, 6)
    }

    private func actions(for block: NoteBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Turn into").font(Brand.Fonts.label).foregroundStyle(Brand.Palette.secondary).padding(.bottom, 2)
            // A divider holds no text, so nothing turns into one.
            ForEach(Self.kinds.filter { $0.kind != .divider && block.kind != .divider }, id: \.name) { item in
                action(item.name, item.symbol) {
                    update(block.id) { changed in
                        changed.kind = item.kind
                        if item.kind == .table, NoteBlocks.table(block.text) == nil { changed.text = Self.emptyTable }
                        if !item.kind.isList { changed.indent = 0 }
                    }
                }
            }
            Divider().padding(.vertical, 3)
            blockActions(for: block)
        }
        .buttonStyle(.hand)
        .padding(12)
        .frame(width: 190, alignment: .leading)
    }

    /// Duplicate and Delete, which every block has.
    @ViewBuilder
    func blockActions(for block: NoteBlock) -> some View {
        action("Duplicate", "plus.square.on.square") {
            change { blocks in
                NoteBlocks.with(block.id, in: &blocks) { list, index in list.insert(NoteBlocks.copy(of: block), at: index + 1) }
            }
        }
        action("Delete", "trash") {
            change { blocks in NoteBlocks.with(block.id, in: &blocks) { list, index in _ = list.remove(at: index) } }
        }
    }

    func action(_ name: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button {
            menuFor = nil
            perform()
        } label: {
            Label(name, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(.rect)
        }
        .font(Brand.Fonts.subtitle)
        .foregroundStyle(Brand.Palette.ink)
    }

    /// What stands before a list item, a checkbox or a quote.
    @ViewBuilder
    private func marker(for block: NoteBlock, number: Int?) -> some View {
        switch block.kind {
        case .bullet:
            Text("•").font(Brand.Fonts.row).foregroundStyle(Brand.Palette.secondary).frame(width: 20, alignment: .leading)
        case .numbered:
            Text("\(number ?? 1).").font(Brand.Fonts.row).monospacedDigit().foregroundStyle(Brand.Palette.secondary)
                .frame(minWidth: 20, alignment: .leading).padding(.trailing, 4)
        case .checkbox(let done):
            Button {
                update(block.id) { $0.kind = .checkbox(!done) }
            } label: {
                CheckBox(checked: done, size: 15)
            }
            .buttonStyle(.hand)
            .padding(.top, 2)
            .padding(.trailing, 8)
            .accessibilityLabel(done ? "Done" : "Not done")
        case .quote:
            RoundedRectangle(cornerRadius: 1.5).fill(Brand.Palette.secondary.opacity(0.5)).frame(width: 3).padding(.trailing, 10)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(of block: NoteBlock) -> some View {
        switch block.kind {
        case .divider:
            Rectangle().fill(Brand.Palette.hairline).frame(height: 1).frame(maxWidth: .infinity).padding(.vertical, 9)
        case .code(let language):
            field(block, size: 13, monospaced: true)
                .padding(10)
                .background(Brand.Palette.field, in: .rect(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Text(language.isEmpty ? "code" : language)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.Palette.secondary)
                        .padding(6)
                        .allowsHitTesting(false)
                }
        case .table:
            if let table = NoteBlocks.table(block.text) {
                TableBlock(header: table.header, rows: table.rows) { header, rows in
                    update(block.id) { $0.text = NoteBlocks.tableMarkdown(header: header, rows: rows) }
                }
            } else {
                // Text that stopped being a table (a line was removed elsewhere) is shown as it is.
                field(block, size: 13, monospaced: true)
            }
        case .heading(let level):
            field(block, size: level == 1 ? 24 : level == 2 ? 19 : 16.5, weight: .bold)
        case .quote:
            field(block, size: 15, dimmed: true)
        case .checkbox(let done):
            field(block, size: 15, dimmed: done)
        case .paragraph, .bullet, .numbered:
            field(block, size: 15)
                .overlay(alignment: .topLeading) {
                    if blocks.count == 1, block.kind == .paragraph, block.text.isEmpty {
                        Text("Write something. Point at a line and press + for a heading, list, checkbox, table, columns and more.")
                            .font(Brand.Fonts.row)
                            .foregroundStyle(Brand.Palette.secondary.opacity(0.7))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
        case .layout:
            EmptyView() // drawn by `layout(_:widths:numbers:)`
        }
    }

    private func field(_ block: NoteBlock, size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false, dimmed: Bool = false) -> some View {
        MarkdownTextField(
            text: Binding(get: { block.text }, set: { setText($0, of: block.id) }),
            fontSize: size, weight: weight, monospaced: monospaced, dimmed: dimmed,
            focus: focusID == block.id ? focus : nil,
            onCommand: { command($0, in: $1, of: block.id) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
