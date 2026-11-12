import AppKit
import SwiftData
import Testing
import WebKit
@testable import Ezra

@MainActor
struct ArtifactTests {
    private let workload = """
        import { useState } from "react";
        import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
        import { Button } from "@/components/ui/button";
        import { Badge } from "@/components/ui/badge";
        import { Flag } from "lucide-react";
        import { Bar, BarChart, XAxis } from "recharts";

        const projects = [{ name: "Move", open: 12 }, { name: "Blog", open: 8 }, { name: "Taxes", open: 4 }];

        export default function Workload() {
          const [sorted, setSorted] = useState(false);
          const rows = sorted ? [...projects].sort((a, b) => a.open - b.open) : projects;
          return (
            <Card className="m-4 border-2">
              <CardHeader><CardTitle id="heading">Workload <Badge>{rows.length} projects</Badge></CardTitle></CardHeader>
              <CardContent>
                <p id="first" className="text-red-600 font-bold"><Flag size={14} /> {rows[0].name}: {rows[0].open}</p>
                <BarChart width={300} height={120} data={rows}><XAxis dataKey="name" /><Bar dataKey="open" fill="#1F63D2" /></BarChart>
                <Button id="sort" onClick={() => setSorted(true)}>Fewest first</Button>
              </CardContent>
            </Card>
          );
        }
        """

    private func load(_ page: ChatPage) async throws -> WKWebView {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        view.loadHTMLString(page.document, baseURL: nil)
        // Long enough for the runtime to start and Tailwind to write its styles.
        try await Task.sleep(for: .seconds(2.5))
        return view
    }

    private func value(_ script: String, in view: WKWebView) async throws -> String {
        "\(try await view.evaluateJavaScript(script) ?? "nil")"
    }

    @Test func aReactArtifactRendersWithComponentsIconsChartsStylingAndState() async throws {
        let (_, container) = try makeWorkspace()
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        let outcome = box.run("buildArtifact", ToolInput(value: .object(["title": .string("Workload"), "code": .string(workload)])))
        let page = try #require(outcome.page, "\(outcome.text)")
        #expect(page.code == workload && page.html.isEmpty)

        let view = try await load(page)
        #expect(try await value("document.getElementById('ezra-error') ? document.getElementById('ezra-error').textContent : ''", in: view) == "")
        #expect(try await value("document.getElementById('heading').textContent", in: view) == "Workload 3 projects")
        #expect(try await value("document.getElementById('first').textContent.trim()", in: view) == "Move: 12")
        // An icon and a chart were drawn, and Tailwind turned the class names into real styles.
        #expect(try await value("document.querySelectorAll('svg').length >= 2", in: view) == "1")
        #expect(try await value("getComputedStyle(document.getElementById('first')).color", in: view) == "rgb(220, 38, 38)")
        #expect(try await value("getComputedStyle(document.getElementById('first')).fontWeight", in: view) == "700")
        // It is live: a click changes what is shown.
        _ = try await value("document.getElementById('sort').click()", in: view)
        try await Task.sleep(for: .seconds(0.4))
        #expect(try await value("document.getElementById('first').textContent.trim()", in: view) == "Taxes: 4")
    }

    @Test func aFaultyArtifactIsSentBackToTheModelWithTheReason() throws {
        let (_, container) = try makeWorkspace()
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        func build(_ code: String) -> ToolOutcome {
            box.run("buildArtifact", ToolInput(value: .object(["title": .string("T"), "code": .string(code)])))
        }
        let broken = build("export default function A() { return <div>oops</div>; ")
        #expect(broken.failed && broken.page == nil && broken.text.contains("does not compile"))
        let stranger = build("import dayjs from \"dayjs\";\nexport default function A() { return <div>{dayjs().format()}</div>; }")
        #expect(stranger.text.contains("\"dayjs\" cannot be imported"))
        #expect(build("export default function A() { fetch('/api'); return <div/>; }").text.contains("it uses fetch("))
        #expect(build("const x = 1;").text.contains("must export a React component"))
        #expect(!build("import { Card } from \"@/components/ui/card\";\nexport default () => <Card>ok</Card>;").failed)
        #expect(ArtifactKit.modules.count == ArtifactKit.components.count + 10)
    }

    @Test func aRuntimeErrorIsShownInThePageNotABlank() async throws {
        let view = try await load(ChatPage(title: "T", html: "", code: "export default function A() { const list: any = null; return <p>{list.length}</p>; }"))
        let shown = try await value("document.getElementById('ezra-error') ? document.getElementById('ezra-error').textContent : ''", in: view)
        #expect(shown.hasPrefix("This artifact could not be shown."), "\(shown)")
    }

    @Test func aDashboardIsDrawnByTheAppFromTheModelsFigures() async throws {
        let (_, container) = try makeWorkspace()
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        let spec = try JSONValue.parse("""
            {"title": "My workload", "dashboard": {
              "subtitle": "Open work across projects",
              "kpis": [{"label": "Open to-dos", "value": 108, "note": "3 overdue", "tone": "bad"}, {"label": "Done this week", "value": "26", "tone": "good"}],
              "charts": [
                {"title": "By project", "type": "bar", "items": [{"label": "Move <flat>", "value": 12}, {"label": "Blog", "value": "8"}]},
                {"title": "By area", "type": "donut", "items": [{"label": "Home", "value": 15}, {"label": "Work", "value": 5}]},
                {"title": "Progress", "type": "progress", "items": [{"label": "Taxes", "value": 40}]},
                {"title": "Completed", "type": "line", "items": [{"label": "Mon", "value": 2}, {"label": "Tue", "value": 5}]}],
              "table": {"title": "Due soon", "columns": ["To-do", "Days"], "rows": [["Sign lease", 1], ["Return headphones", 5], ["File taxes", 13]]},
              "notes": ["Most open work is in the move."]}}
            """)
        let outcome = box.run("showDashboard", ToolInput(value: spec))
        let page = try #require(outcome.page, "\(outcome.text)")
        // Text from the model is shown as text, never as markup.
        #expect(page.html.contains("Move &lt;flat&gt;") && !page.html.contains("<flat>"))

        let view = try await load(page)
        #expect(try await value("document.querySelector('h1').textContent", in: view) == "My workload")
        #expect(try await value("document.querySelectorAll('.kpi').length + '/' + document.querySelectorAll('.charts .card').length", in: view) == "2/4")
        #expect(try await value("document.querySelector('.kpi .value').textContent + ' ' + document.querySelector('.note.bad').textContent", in: view) == "108 3 overdue")
        #expect(try await value("document.querySelector('.bar .track div').style.width", in: view) == "100%")
        #expect(try await value("document.querySelectorAll('.donut circle').length + document.querySelectorAll('svg.line circle').length", in: view) == "4")
        // Clicking a heading sorts the table, numbers as numbers.
        _ = try await value("document.querySelectorAll('th')[1].click(); document.querySelectorAll('th')[1].click()", in: view)
        #expect(try await value("document.querySelector('tbody tr td').textContent", in: view) == "File taxes")

        // A dashboard with nothing in it is sent back.
        let empty = box.run("showDashboard", ToolInput(value: .object(["title": .string("T"), "dashboard": .object(["subtitle": .string("x")])])))
        #expect(empty.failed && empty.page == nil)
        #expect(AgentTools.showDashboard.schema["properties"]?["dashboard"]?["properties"]?["kpis"]?["type"] == .string("array"))
    }

    @Test func theWorkloadDashboardIsWorkedOutFromTheStore() throws {
        let (workspace, container) = try makeWorkspace()
        let home = try workspace.addArea(name: "Home")
        let move = try workspace.addProject(name: "Move", area: home)
        let blog = try workspace.addProject(name: "Blog")
        try workspace.addToDo(title: "Sign lease", project: move, deadline: SmartList.day(-1))
        try workspace.addToDo(title: "Pack books", project: move, schedule: .on(.now), deadline: SmartList.day(3))
        try workspace.addToDo(title: "Write post", project: blog)
        try workspace.addToDo(title: "Loose idea")
        try workspace.setCompleted(try workspace.addToDo(title: "Book movers", project: move), true)
        let dashboard = Dashboard.workload(todos: try workspace.allToDos(), projects: try workspace.projects())
        #expect(dashboard.kpis?.map { "\($0.label)=\($0.value.text)" } == ["Open to-dos=4", "Due this week=1", "Overdue=1", "Done this week=1"])
        #expect(dashboard.kpis?[2].tone == "bad")
        let charts = try #require(dashboard.charts)
        #expect(charts[0].items.map { "\($0.label)=\($0.value.text)" } == ["Move=2", "Blog=1"])
        #expect(Set(charts[1].items.map { "\($0.label)=\($0.value.text)" }) == ["Home=2", "No area=2"])
        #expect(charts[2].items.count == 7 && charts[2].items.last?.value.text == "1")
        #expect(charts[3].items.first.map { "\($0.label)=\($0.value.text)" } == "Move=33")
        #expect(dashboard.table?.rows.map { $0[0].text } == ["Sign lease", "Pack books"])
        #expect(dashboard.notes?.first == "Move holds the most open work (2 to-dos).")
        #expect(dashboard.notes?.contains("1 to-do in the Inbox still need a place.") == true)

        // One call with no arguments shows it, and tells the model the figures so it does not have to guess.
        let box = AgentToolbox(container: container, reminders: nil) { _ in }
        let outcome = box.run("showWorkload", ToolInput(value: .object([:])))
        #expect(outcome.page?.html.contains("Next deadlines") == true && outcome.text.contains("Open to-dos: 4"))
    }
}
