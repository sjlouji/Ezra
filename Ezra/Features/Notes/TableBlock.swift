import SwiftUI

/// A table in a note, edited cell by cell. Rows and columns are added with the buttons at its edges and removed by
/// right-clicking a cell.
struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    /// Called with the whole table whenever a cell, row or column changes.
    let changed: ([String], [[String]]) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ForEach(header.indices, id: \.self) { column in
                                cell(header[column], row: nil, column: column).fontWeight(.semibold)
                            }
                        }
                        ForEach(rows.indices, id: \.self) { row in
                            Divider().overlay(Brand.Palette.hairline)
                            GridRow {
                                ForEach(header.indices, id: \.self) { column in
                                    cell(column < rows[row].count ? rows[row][column] : "", row: row, column: column)
                                }
                            }
                        }
                    }
                    .font(Brand.Fonts.row)
                }
                .background(Brand.Palette.page, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.Palette.hairline))
                add("Add Row") { changed(header, rows + [header.map { _ in "" }]) }
            }
            add("Add Column") { changed(header + [""], rows.map { $0 + [""] }) }.padding(.top, 8)
        }
    }

    private func add(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: "plus", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.hand)
            .font(.system(size: 12))
            .foregroundStyle(Brand.Palette.secondary)
            .help(label)
    }

    /// One editable cell; `row` is nil for the header.
    private func cell(_ text: String, row: Int?, column: Int) -> some View {
        TextField(row == nil ? "Column" : "", text: Binding(get: { text }, set: { set($0, row: row, column: column) }))
            .textFieldStyle(.plain)
            .frame(minWidth: 110, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .contextMenu {
                if let row {
                    Button("Delete Row") { changed(header, rows.enumerated().filter { $0.offset != row }.map(\.element)) }
                }
                if header.count > 1 {
                    Button("Delete Column") {
                        func without(_ cells: [String]) -> [String] { cells.enumerated().filter { $0.offset != column }.map(\.element) }
                        changed(without(header), rows.map(without))
                    }
                }
            }
    }

    private func set(_ text: String, row: Int?, column: Int) {
        var (header, rows) = (header, rows)
        if let row {
            // A short row is filled out first, so the cell being typed in exists.
            while rows[row].count < header.count { rows[row].append("") }
            rows[row][column] = text
        } else {
            header[column] = text
        }
        changed(header, rows)
    }
}
