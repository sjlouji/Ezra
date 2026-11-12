import Foundation

/// A dashboard the model describes with data only. The app draws it, so every dashboard looks the same and looks right
/// whichever model supplied the numbers.
struct Dashboard: Decodable {
    /// A number or text as the model sent it; models are loose about which they use.
    struct Loose: Decodable {
        let text: String
        var number: Double { Double(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")) ?? 0 }

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) {
                text = number == number.rounded() ? String(Int(number)) : String(format: "%.1f", number)
            } else {
                text = try value.decode(String.self)
            }
        }
    }

    struct KPI: Decodable {
        let label: String
        let value: Loose
        var note: String?
        /// "good", "bad" or anything else for neutral.
        var tone: String?
    }

    struct Item: Decodable {
        let label: String
        let value: Loose
    }

    struct Chart: Decodable {
        let title: String
        /// "bar", "line", "donut" or "progress" (values are percentages).
        var type: String?
        let items: [Item]
    }

    struct Table: Decodable {
        var title: String?
        let columns: [String]
        let rows: [[Loose]]
    }

    var subtitle: String?
    var kpis: [KPI]?
    var charts: [Chart]?
    var table: Table?
    var notes: [String]?

    private static let colours = ["#1F63D2", "#2F9C8E", "#F2B01E", "#E6455F", "#6E86C9", "#4FB35B", "#B07CD8", "#8E8E93"]

    /// What the model is asked to send, as a JSON Schema.
    static let schema: JSONValue = {
        func text(_ about: String) -> JSONValue { .object(["type": .string("string"), "description": .string(about)]) }
        func list(_ item: JSONValue, _ about: String) -> JSONValue { .object(["type": .string("array"), "description": .string(about), "items": item]) }
        func object(_ fields: [String: JSONValue], required: [String]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(fields), "required": .array(required.map(JSONValue.string))])
        }
        let item = object(["label": text("Its name"), "value": .object(["type": .string("number")])], required: ["label", "value"])
        return object([
            "subtitle": text("One line under the title: what this covers"),
            "kpis": list(object([
                "label": text("What the number is, two or three words"), "value": text("The number, as text"),
                "note": text("A few words of context, such as '3 due this week'"), "tone": text("good, bad or neutral"),
            ], required: ["label", "value"]), "Two to four headline numbers"),
            "charts": list(object([
                "title": text("What the chart shows"), "type": text("bar, line, donut, or progress (values are percentages 0 to 100)"),
                "items": list(item, "The values, in the order to show them"),
            ], required: ["title", "items"]), "One to four charts"),
            "table": object([
                "title": text("A heading for the table"), "columns": list(text("A column heading"), "The column headings"),
                "rows": list(list(text("A cell"), "One row, a cell per column"), "The rows"),
            ], required: ["columns", "rows"]),
            "notes": list(text("One observation"), "Two to four short observations worth acting on"),
        ], required: [])
    }()

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The whole page.
    func html(title: String, now: Date = .now) -> String {
        let e = Self.escaped
        var body = """
            <header><div><h1>\(e(title))</h1>\(subtitle.map { "<p class=\"sub\">\(e($0))</p>" } ?? "")</div>\
            <time>\(e(now.formatted(date: .abbreviated, time: .shortened)))</time></header>
            """
        if let kpis, !kpis.isEmpty {
            body += "<section class=\"kpis\">" + kpis.prefix(4).map { kpi in
                "<div class=\"kpi\"><span class=\"label\">\(e(kpi.label))</span><span class=\"value\">\(e(kpi.value.text))</span>"
                    + (kpi.note.map { "<span class=\"note \(kpi.tone == "good" ? "good" : kpi.tone == "bad" ? "bad" : "")\">\(e($0))</span>" } ?? "") + "</div>"
            }.joined() + "</section>"
        }
        if let charts, !charts.isEmpty {
            body += "<section class=\"charts\">" + charts.prefix(4).map { "<div class=\"card\"><h2>\(e($0.title))</h2>\(Self.drawing(of: $0))</div>" }.joined() + "</section>"
        }
        if let table, !table.columns.isEmpty {
            body += "<section class=\"card\">\(table.title.map { "<h2>\(e($0))</h2>" } ?? "")<table><thead><tr>"
                + table.columns.map { "<th>\(e($0))</th>" }.joined() + "</tr></thead><tbody>"
                + table.rows.map { row in "<tr>" + row.map { "<td>\(e($0.text))</td>" }.joined() + "</tr>" }.joined() + "</tbody></table></section>"
        }
        if let notes, !notes.isEmpty {
            body += "<section class=\"card notes\"><h2>Worth noticing</h2><ul>" + notes.map { "<li>\(e($0))</li>" }.joined() + "</ul></section>"
        }
        return "<html><head><style>\(Self.style)</style></head><body>\(body)<script>\(Self.script)</script></body></html>"
    }

    private static func drawing(of chart: Chart) -> String {
        let e = escaped
        let items = Array(chart.items.prefix(12))
        let top = max(items.map(\.value.number).max() ?? 0, 0.0001)
        switch chart.type {
        case "donut":
            let total = max(items.reduce(0) { $0 + max($1.value.number, 0) }, 0.0001)
            var (start, arcs) = (0.0, "")
            for (index, item) in items.enumerated() {
                let share = max(item.value.number, 0) / total
                // Each slice is a stroke along part of the circle: its length, then a gap for the rest.
                arcs += "<circle r=\"40\" cx=\"60\" cy=\"60\" fill=\"none\" stroke=\"\(colours[index % colours.count])\" stroke-width=\"18\" "
                    + "stroke-dasharray=\"\(share * 251.33) 251.33\" stroke-dashoffset=\"\(-start * 251.33)\" transform=\"rotate(-90 60 60)\"><title>\(e(item.label)): \(e(item.value.text))</title></circle>"
                start += share
            }
            let legend = items.enumerated().map { index, item in
                "<li><i style=\"background:\(colours[index % colours.count])\"></i>\(e(item.label))<b>\(e(item.value.text))</b></li>"
            }.joined()
            return "<div class=\"donut\"><svg viewBox=\"0 0 120 120\" width=\"120\" height=\"120\">\(arcs)</svg><ul class=\"legend\">\(legend)</ul></div>"
        case "line":
            let (width, height) = (300.0, 110.0)
            let step = items.count > 1 ? width / Double(items.count - 1) : 0
            let points = items.enumerated().map { index, item in (Double(index) * step, height - item.value.number / top * (height - 14) - 4) }
            let path = points.map { "\($0.0),\($0.1)" }.joined(separator: " ")
            let dots = zip(points, items).map { point, item in
                "<circle cx=\"\(point.0)\" cy=\"\(point.1)\" r=\"3.5\" fill=\"#1F63D2\"><title>\(e(item.label)): \(e(item.value.text))</title></circle>"
            }.joined()
            let labels = items.map { "<span>\(e($0.label))</span>" }.joined()
            return "<svg class=\"line\" viewBox=\"-6 0 312 \(height)\" preserveAspectRatio=\"none\"><polyline points=\"\(path)\" fill=\"none\" stroke=\"#1F63D2\" stroke-width=\"2\"/>\(dots)</svg><div class=\"axis\">\(labels)</div>"
        default:
            let isProgress = chart.type == "progress"
            return "<div class=\"bars\">" + items.enumerated().map { index, item in
                let share = min(max(item.value.number / (isProgress ? 100 : top), 0), 1) * 100
                return "<div class=\"bar\"><span>\(e(item.label))</span><div class=\"track\"><div style=\"width:\(share)%;background:\(isProgress ? "#1F63D2" : colours[index % colours.count])\"></div></div><b>\(e(item.value.text))\(isProgress ? "%" : "")</b></div>"
            }.joined() + "</div>"
        }
    }

    private static let style = """
        * { box-sizing: border-box; }
        body { font: 13px -apple-system, "SF Pro Text", sans-serif; color: #26282C; background: #F4F5F7; margin: 0; padding: 16px; }
        header { display: flex; justify-content: space-between; align-items: flex-end; margin-bottom: 14px; }
        h1 { font-size: 19px; margin: 0; letter-spacing: -0.2px; }
        h2 { font-size: 12px; margin: 0 0 10px; color: #6B6E76; font-weight: 600; text-transform: uppercase; letter-spacing: 0.4px; }
        .sub, time { color: #8E8E93; font-size: 12px; margin: 3px 0 0; }
        section { margin-bottom: 12px; }
        .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 10px; }
        .kpi, .card { background: #fff; border: 1px solid #E6E7EA; border-radius: 10px; padding: 12px 14px; }
        .kpi { display: flex; flex-direction: column; gap: 2px; }
        .kpi .label { color: #6B6E76; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.4px; }
        .kpi .value { font-size: 26px; font-weight: 700; letter-spacing: -0.5px; }
        .note { font-size: 11.5px; color: #8E8E93; } .note.good { color: #2E8B45; } .note.bad { color: #D2334A; }
        .charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 10px; }
        .bar { display: grid; grid-template-columns: minmax(80px, 46%) 1fr auto; gap: 8px; align-items: center; margin: 6px 0; }
        .bar span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .track { height: 9px; background: #EEEFF2; border-radius: 5px; overflow: hidden; }
        .track div { height: 100%; border-radius: 5px; transition: width .5s ease; }
        .bar b, .legend b { font-variant-numeric: tabular-nums; }
        .donut { display: flex; gap: 14px; align-items: center; }
        .legend { list-style: none; margin: 0; padding: 0; flex: 1; } .legend li { display: flex; gap: 6px; align-items: center; margin: 4px 0; }
        .legend i { width: 9px; height: 9px; border-radius: 2px; } .legend b { margin-left: auto; }
        svg.line { width: 100%; height: 110px; overflow: visible; }
        .axis { display: flex; justify-content: space-between; color: #8E8E93; font-size: 10.5px; margin-top: 4px; }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: left; font-size: 11px; color: #6B6E76; text-transform: uppercase; letter-spacing: 0.4px; padding: 6px 8px; border-bottom: 1px solid #E6E7EA; cursor: pointer; user-select: none; }
        th:hover { color: #1F63D2; } th.sorted::after { content: " ↓"; } th.sorted.up::after { content: " ↑"; }
        td { padding: 7px 8px; border-bottom: 1px solid #F0F1F3; } tr:last-child td { border-bottom: 0; } tbody tr:hover { background: #F7F8FA; }
        .notes ul { margin: 0; padding-left: 18px; } .notes li { margin: 4px 0; }
        """

    /// Clicking a column heading sorts the table by it, numbers as numbers.
    private static let script = """
        document.querySelectorAll("th").forEach(function (heading, column) {
          heading.addEventListener("click", function () {
            var body = heading.closest("table").querySelector("tbody"), up = !heading.classList.contains("up");
            var rows = Array.prototype.slice.call(body.rows);
            rows.sort(function (a, b) {
              var x = a.cells[column].textContent, y = b.cells[column].textContent, n = parseFloat(x), m = parseFloat(y);
              var order = isNaN(n) || isNaN(m) ? x.localeCompare(y) : n - m;
              return up ? order : -order;
            });
            heading.parentNode.querySelectorAll("th").forEach(function (other) { other.classList.remove("sorted", "up"); });
            heading.classList.add("sorted"); if (up) heading.classList.add("up");
            rows.forEach(function (row) { body.appendChild(row); });
          });
        });
        """
}
