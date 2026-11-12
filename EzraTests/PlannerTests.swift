import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Ezra

@MainActor
struct PlannerTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        SmartList.day(day).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    @Test func eventsSitOnTheGridByTheirTimes() {
        let half = Planner.frame(start: at(9), end: at(9, 30), on: today, hourHeight: 60)
        #expect(half.y == 180 && half.height == 30)
        let tiny = Planner.frame(start: at(10), end: at(10, 5), on: today, hourHeight: 60)
        #expect(tiny.y == 240 && tiny.height == 26)
        let early = Planner.frame(start: at(4), end: at(7), on: today, hourHeight: 60)
        #expect(early.y == 0 && early.height == 60)
    }

    @Test func aDayShowsItsOwnToDosAndTodayAlsoShowsOverdueOnes() throws {
        let (workspace, _) = try makeWorkspace()
        try workspace.addToDo(title: "Late", schedule: .on(SmartList.day(-2)))
        try workspace.addToDo(title: "Now", schedule: .on(today))
        try workspace.addToDo(title: "Friday", schedule: .on(SmartList.day(3)))
        try workspace.addToDo(title: "Loose")
        let all = try workspace.allToDos()

        #expect(Planner.todos(on: today, from: all).map(\.title) == ["Late", "Now"])
        #expect(Planner.todos(on: SmartList.day(3), from: all).map(\.title) == ["Friday"])
        #expect(Planner.todos(on: SmartList.day(1), from: all).isEmpty)
        #expect(Planner.backlog(from: all).map(\.title) == ["Loose"])
    }

    @Test func eventsBelongToTheDayTheyTouch() throws {
        let (workspace, _) = try makeWorkspace()
        let meeting = try workspace.addEvent(title: "Meeting", start: at(14))
        #expect(meeting.end == at(15))
        let allDay = try workspace.addEvent(title: "Holiday", start: today, end: SmartList.day(1), isAllDay: true)
        try workspace.addEvent(title: "Tomorrow", start: at(9, day: 1))
        let all = try workspace.events()

        #expect(Planner.events(on: today, from: all) == [allDay, meeting])
        #expect(Planner.events(on: SmartList.day(1), from: all).map(\.title) == ["Tomorrow"])
        #expect(throws: WorkspaceError.emptyName(kind: "event")) { try workspace.addEvent(title: " ", start: .now) }
    }

    @Test func aToDoAddedFromAnEventNoteJoinsTheEventItsProjectAndBucket() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Winter menu")
        let event = try workspace.addEvent(title: "Menu tasting", start: at(14), project: project)
        let app = AppModel()
        app.context = workspace.context

        app.newToDo(bucket: .fire, event: event, inBacklog: true)
        let added = try #require(app.card?.todo)
        added.title = "Order squash"
        app.closeCard()

        #expect(added.event == event && added.project == project && added.bucket == .fire)
        #expect(event.openToDos == [added])
        #expect(Planner.backlog(from: try workspace.allToDos()) == [added])
    }

    @Test func thePlannerAddsToTheDayItIsShowing() throws {
        let (workspace, _) = try makeWorkspace()
        let app = AppModel()
        app.context = workspace.context
        app.destination = .planner
        app.day = SmartList.day(2)
        app.newToDo(bucket: .growth)
        try #require(app.card?.todo).title = "Later this week"
        app.closeCard()
        #expect(Planner.todos(on: SmartList.day(2), from: try workspace.allToDos()).map(\.title) == ["Later this week"])
    }

    @Test func demoEventsAreSeededAndMoveWithTheDates() throws {
        let (workspace, _) = try makeWorkspace()
        let name = "ezra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let seedDay = Date.now
        try Seeder.prepare(context: workspace.context, defaults: defaults, now: seedDay)
        #expect(try workspace.events().count == Fixtures.events.count)
        #expect(Planner.events(on: seedDay, from: try workspace.events()).count == 5)

        let later = SmartList.day(2, from: seedDay).addingTimeInterval(60)
        try Seeder.prepare(context: workspace.context, defaults: defaults, now: later)
        #expect(Planner.events(on: later, from: try workspace.events()).count == 5)

        try Seeder.removeDemo(context: workspace.context)
        #expect(try workspace.events().isEmpty)
    }

    /// Renders the planner with the demo data and attaches the picture to the test results. Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"), arguments: [330, 620, 1180])
    func plannerSnapshot(width: Int) async throws {
        let (workspace, container) = try makeWorkspace()
        let defaults = try #require(UserDefaults(suiteName: "ezra.tests.\(UUID().uuidString)"))
        try Seeder.seed(context: workspace.context, defaults: defaults)
        let app = AppModel()
        if width > 1000 { app.openEvent = try workspace.events().first { !$0.noteBody.isEmpty } }
        if width == 620 {
            app.context = workspace.context
            app.open(try workspace.findToDo("Buy party decorations"))
        }
        try await attach(PlannerView(), app: app, container: container, size: CGSize(width: width, height: 700), named: "planner-\(width)")
    }

    /// A project screen with one to-do open in place. Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"))
    func projectSnapshot() async throws {
        let (workspace, container) = try makeWorkspace()
        let defaults = try #require(UserDefaults(suiteName: "ezra.tests.\(UUID().uuidString)"))
        try Seeder.seed(context: workspace.context, defaults: defaults)
        let app = AppModel()
        app.context = workspace.context
        let project = try workspace.findProject("Throw Party for Eve")
        app.open(try workspace.findToDo("Confirm guest list"))
        try await attach(ProjectView(project: project), app: app, container: container, size: CGSize(width: 760, height: 700), named: "project")
    }

    /// The whole window on one screen, as the app shows it. Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"), arguments: ["today", "repeat", "when", "quickfind", "move", "assistant", "assistant-empty", "planner-week", "planner-month", "planner-year", "today-dark", "assistant-dark", "today-nosidebar", "planner-month-nosidebar", "notes-project", "notes-todo", "notes-page", "notes-inbox", "notes-owner", "notes-find", "notes-layout"])
    func windowSnapshot(screen name: String) async throws {
        let screen = name.replacingOccurrences(of: "-dark", with: "").replacingOccurrences(of: "-nosidebar", with: "")
        // The sidebar's state is a saved preference; put back whatever the user had.
        let savedSidebar = UserDefaults.standard.bool(forKey: "sidebar.hidden")
        defer { UserDefaults.standard.set(savedSidebar, forKey: "sidebar.hidden") }
        UserDefaults.standard.set(name.hasSuffix("-nosidebar"), forKey: "sidebar.hidden")
        let (workspace, container) = try makeWorkspace()
        let defaults = try #require(UserDefaults(suiteName: "ezra.tests.\(UUID().uuidString)"))
        try Seeder.seed(context: workspace.context, defaults: defaults)
        let app = AppModel()
        switch screen {
        case "when", "move", "repeat": app.destination = .project(try workspace.findProject("Prepare Presentation"))
        case "upcoming": app.destination = .list(.upcoming)
        case "planner-week", "planner-month", "planner-year": app.destination = .planner
        case "assistant": app.destination = .assistant
        default: app.destination = .list(.today)
        }
        if screen.hasPrefix("notes-") { try showNoteWorkflow(screen, app: app, workspace: workspace) }
        // The planner remembers its view in the app's preferences; put back whatever the user had.
        let savedMode = UserDefaults.standard.string(forKey: "planner.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "planner.mode") }
        if screen.hasPrefix("planner-") { UserDefaults.standard.set(String(screen.dropFirst(8)), forKey: "planner.mode") }
        let size = CGSize(width: 1060, height: 760)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if name.hasSuffix("-dark") { window.appearance = NSAppearance(named: .darkAqua) }
        let chat = makeChat(container, engine: .claude, key: "snapshot")
        if screen == "assistant" { try seedChat(chat, workspace) }
        if screen == "assistant-empty" { app.destination = .assistant }
        let host = NSHostingView(rootView: RootView(container: container, app: app, chat: chat).modelContainer(container))
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1.5))
        if ["when", "move", "repeat"].contains(screen) {
            app.context = workspace.context
            let todo = try workspace.findToDo("Finish slide outline")
            try workspace.setReminder(todo, at: SmartList.day(0).addingTimeInterval(14.5 * 3600))
            todo.notes = "Use the **brand** template.\n- three slides\n- ::one:: idea each"
            app.open(todo)
            if screen == "when" { app.pick(.when, for: todo) }
            if screen == "move" { app.moving = todo }
            if screen == "repeat" {
                try workspace.setRepeat(todo, RepeatRule())
                app.destination = .special(.repeating)
            }
            try await Task.sleep(for: .seconds(0.8))
        }
        if screen == "notes-find" {
            app.quickFindSeed = "retry"
            app.setQuickFind(true)
            try await Task.sleep(for: .seconds(0.8))
        }
        if screen == "quickfind" {
            app.quickFindSeed = "pre"
            app.setQuickFind(true)
            try await Task.sleep(for: .seconds(0.8))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "window-\(name).png")
    }

    /// Renders a screen offscreen and attaches the picture to the test results.
    private func attach(_ screen: some View, app: AppModel, container: ModelContainer, size: CGSize, named name: String) async throws {
        let view = screen
            .environment(app)
            .environment(Library(context: container.mainContext))
            .modelContainer(container)
            .preferredColorScheme(.light)
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .seconds(1.5))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "\(name).png")
        window.close()
    }

    /// Frames through the open animation and through a drag, tiled into one picture each. Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"))
    func motionStrips() async throws {
        let (workspace, container) = try makeWorkspace()
        let defaults = try #require(UserDefaults(suiteName: "ezra.tests.\(UUID().uuidString)"))
        try Seeder.seed(context: workspace.context, defaults: defaults)
        let app = AppModel()
        app.context = workspace.context
        let project = try workspace.findProject("Throw Party for Eve")
        let size = CGSize(width: 760, height: 520)
        let view = DragHarness(app: app) { ProjectView(project: project) }
            .environment(app)
            .environment(Library(context: container.mainContext))
            .modelContainer(container)
            .preferredColorScheme(.light)
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .seconds(1.5))

        func frame() throws -> NSBitmapImageRep {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        func strip(_ frames: [NSBitmapImageRep], named name: String) throws {
            let cell = CGSize(width: size.width * 0.5, height: size.height * 0.5)
            let columns = 4
            let rows = (frames.count + columns - 1) / columns
            let sheet = NSImage(size: CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)))
            sheet.lockFocus()
            NSColor.darkGray.setFill()
            CGRect(origin: .zero, size: sheet.size).fill()
            for (index, bitmap) in frames.enumerated() {
                let origin = CGPoint(x: CGFloat(index % columns) * cell.width, y: CGFloat(rows - 1 - index / columns) * cell.height)
                bitmap.draw(in: CGRect(origin: origin, size: cell).insetBy(dx: 2, dy: 2))
            }
            sheet.unlockFocus()
            let tiff = try #require(sheet.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            Attachment.record(png, named: "\(name).png")
        }

        // Opening: 8 frames, 45 ms apart, starting the moment the to-do is opened.
        var frames = [try frame()]
        app.open(try workspace.findToDo("Send invitations"))
        for _ in 0..<7 {
            try await Task.sleep(for: .milliseconds(45))
            frames.append(try frame())
        }
        try strip(frames, named: "open-strip")
        app.closeCard()
        try await Task.sleep(for: .seconds(0.8))

        // Dragging "Order the birthday cake" down past "Buy drinks and snacks", then releasing.
        let dragged = try workspace.findToDo("Order the birthday cake")
        let slot = try #require(app.slots.values.first { $0.todo == dragged })
        var point = CGPoint(x: slot.frame.minX + 120, y: slot.frame.midY)
        frames = [try frame()]
        for step in 0..<6 {
            point.y += 11
            app.dragChanged(.todo(dragged), at: point, from: slot.frame)
            try await Task.sleep(for: .milliseconds(60))
            frames.append(try frame())
            if step == 5 { app.dragEnded() }
        }
        try await Task.sleep(for: .milliseconds(120))
        frames.append(try frame())
        try strip(frames, named: "drag-strip")
        window.close()
    }
}

/// Hosts a screen the way the window does: in the drag coordinate space, with the lifted item drawn on top.
private struct DragHarness<Screen: View>: View {
    let app: AppModel
    @ViewBuilder let screen: Screen

    var body: some View {
        screen
            .overlay { DragLayer() }
    }
}
