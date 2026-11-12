import SwiftUI

/// Layouts: blocks side by side in columns, or in a grid of cells. Also where a dragged block lands, since with
/// layouts that can be a cell as well as a place in the note.
extension BlockEditor {
    /// The layouts the Add menu offers: the widths of the columns and how many cells to start with.
    static let layouts: [(name: String, symbol: String, widths: [Int], cells: Int)] = [
        ("2 Columns", "rectangle.split.2x1", [1, 1], 2), ("3 Columns", "rectangle.split.3x1", [1, 1, 1], 3),
        ("4 Columns", "square.split.2x2", [1, 1, 1, 1], 4),
        ("Wide Left", "rectangle.leadinghalf.inset.filled", [2, 1], 2), ("Wide Right", "rectangle.trailinghalf.inset.filled", [1, 2], 2),
        ("Grid 2 × 2", "square.grid.2x2", [1, 1], 4), ("Grid 3 × 2", "square.grid.3x2", [1, 1, 1], 6),
    ]

    /// The cells in rows of as many as there are columns; each cell holds blocks of its own.
    func layout(_ block: NoteBlock, widths: [Int], numbers: [UUID: Int]) -> some View {
        let rows = stride(from: 0, to: block.cells.count, by: max(widths.count, 1)).map { Array($0..<min($0 + widths.count, block.cells.count)) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { cells in
                ColumnRow(widths: widths.map { CGFloat($0) }, spacing: 8) {
                    ForEach(cells, id: \.self) { cell in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(block.cells[cell]) { inner in
                                row(inner, numbers: numbers, inCell: true)
                            }
                            // A cell is as tall as the tallest in its row; the room left over stays empty, not shared among its blocks.
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Brand.Palette.field.opacity(0.45), in: .rect(cornerRadius: 8))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                            cellFrames[CellRef(layout: block.id, index: cell)] = $0
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What can be done with a whole layout: more or fewer columns and cells, taking it apart, deleting it.
    func layoutActions(for block: NoteBlock, widths: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Layout").font(Brand.Fonts.label).foregroundStyle(Brand.Palette.secondary).padding(.bottom, 2)
            action("Add Column", "rectangle.split.3x1") {
                update(block.id) { layout in
                    // A single row of columns grows by a cell too, so the new column has one.
                    if layout.cells.count == widths.count { layout.cells.append([NoteBlock(kind: .paragraph)]) }
                    layout.kind = .layout(widths + [1])
                }
            }
            if widths.count > 1 {
                action("Remove Column", "rectangle.split.2x1") { update(block.id) { $0.kind = .layout(Array(widths.dropLast())) } }
            }
            action("Add Cell", "plus.square") { update(block.id) { $0.cells.append([NoteBlock(kind: .paragraph)]) } }
            if block.cells.count > 1, let last = block.cells.last, last.allSatisfy({ $0.kind == .paragraph && $0.text.isEmpty }) {
                action("Remove Last Cell", "minus.square") { update(block.id) { $0.cells.removeLast() } }
            }
            action("Equal Widths", "equal") { update(block.id) { $0.kind = .layout(widths.map { _ in 1 }) } }
            Divider().padding(.vertical, 3)
            action("Remove Layout, Keep Text", "rectangle.portrait") {
                change { blocks in
                    NoteBlocks.with(block.id, in: &blocks) { list, index in list.replaceSubrange(index...index, with: block.cells.flatMap { $0 }) }
                }
            }
            blockActions(for: block)
        }
        .buttonStyle(.hand)
        .padding(12)
        .frame(width: 210, alignment: .leading)
    }

    // MARK: Dragging

    /// Where a dragged block would land: in which run of blocks (a cell, or the note when nil), at which place, and where
    /// the line showing it is drawn.
    struct Drop {
        let cell: CellRef?
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    var drop: Drop? {
        guard let drag, let dragged = NoteBlocks.siblings(of: drag.id, in: blocks).map({ $0.list[$0.index] }) else { return nil }
        // The smallest cell under the pointer takes the block; a layout is not dropped into a cell.
        let cell = dragged.kind.isLayout ? nil : cellFrames
            // Only cells that still exist: a removed cell's last known place is not somewhere to drop.
            .filter { key, frame in
                frame.contains(drag.at) && NoteBlocks.siblings(of: key.layout, in: blocks).map { $0.list[$0.index].cells.indices.contains(key.index) } == true
            }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
        let list = cell.flatMap { cell in NoteBlocks.siblings(of: cell.key.layout, in: blocks).map { $0.list[$0.index].cells[cell.key.index] } } ?? blocks
        let rest = list.filter { $0.id != drag.id }.compactMap { frames[$0.id] }
        let index = rest.count { $0.midY < drag.at.y }
        let whole = blocks.compactMap { frames[$0.id] }.reduce(CGRect.null) { $0.union($1) }
        let area = cell?.value ?? whole
        guard !area.isNull else { return nil }
        let y = index == 0 ? (rest.first?.minY ?? area.minY) : rest[index - 1].maxY
        let inset: CGFloat = cell == nil ? Self.gutter : 32
        return Drop(cell: cell?.key, index: index, x: area.minX + inset, y: y, width: max(area.width - inset, 20))
    }

    func endDrag() {
        guard let drag, let drop else { return self.drag = nil }
        self.drag = nil
        change { NoteBlocks.move(drag.id, to: drop.cell, at: drop.index, in: &$0) }
    }
}

/// Lays its children out side by side in columns of the given relative widths, all as tall as the tallest.
struct ColumnRow: Layout {
    let widths: [CGFloat]
    let spacing: CGFloat

    private func columns(in width: CGFloat) -> [CGFloat] {
        let total = max(widths.reduce(0, +), 1)
        let room = max(width - spacing * CGFloat(max(widths.count - 1, 0)), 0)
        return widths.map { room * $0 / total }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.map { $0.isFinite ? $0 : 600 } ?? 600
        let columns = columns(in: width)
        let height = zip(subviews, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columns(in: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
