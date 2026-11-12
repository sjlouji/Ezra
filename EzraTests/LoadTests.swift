import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Ezra

/// Measures the heavy operations on a large made-up data set. Run with TEST_RUNNER_EZRA_LOAD=<number of to-dos>.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EZRA_LOAD"] != nil))
struct LoadTests {
    private func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = Date.now
        let result = try work()
        print("EZRA-LOAD \(label): \(String(format: "%.0f", Date.now.timeIntervalSince(start) * 1000)) ms")
        return result
    }

    @Test func theHeavyOperationsAtScale() async throws {
        let count = Int(ProcessInfo.processInfo.environment["EZRA_LOAD"] ?? "") ?? 5000
        let (workspace, container) = try makeWorkspace()
        let made = try timed("generate and save \(count) to-dos") { try LoadTest.fill(workspace.context, todos: count) }
        print("EZRA-LOAD data: \(made)")
        let todos = try timed("fetch every to-do") { try workspace.allToDos() }
        for list in SmartList.allCases {
            let found = timed("filter \(list.rawValue)") { todos.filter { list.contains($0) } }
            print("EZRA-LOAD   \(list.rawValue) holds \(found.count)")
        }
        _ = try timed("search (text in titles, notes, tags)") {
            try AgentToolbox(container: container, reminders: nil) { _ in }.tools.first { $0.name == "search" }?.body(workspace, ToolInput(value: .object(["query": .string("budget")])))
        }
        _ = try timed("workload dashboard") { Dashboard.workload(todos: todos, projects: try workspace.projects()).html(title: "x") }
        _ = timed("widget snapshot") { WidgetFeed.snapshot(todos: todos) }
        _ = try timed("calendar load for a year") { Planner.load(todos: todos, events: try workspace.events()) }
        _ = try timed("sync: snapshot and fingerprint everything") { try SyncStore(context: workspace.context).snapshot() }
        _ = try timed("backlinks for one note") { try workspace.backlinks(to: try #require(try workspace.notes().first)) }

        // The screens themselves: how long until each has laid itself out in a window.
        // The planner remembers its view in the app's preferences; put back whatever the user had.
        let savedMode = UserDefaults.standard.string(forKey: "planner.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "planner.mode") }
        for (name, destination) in [("Today", Destination.list(.today)), ("Upcoming", .list(.upcoming)), ("Anytime", .list(.anytime)), ("Logbook", .list(.logbook)),
                                    ("Planner day", .planner), ("Planner week", .planner), ("Planner month", .planner), ("Planner year", .planner),
                                    ("Notes", .special(.allNotes)), ("Assistant", .assistant)] {
            if name.hasPrefix("Planner ") { UserDefaults.standard.set(String(name.dropFirst(8)), forKey: "planner.mode") }
            let app = AppModel()
            app.destination = destination
            let start = Date.now
            let host = NSHostingView(rootView: RootView(container: container, app: app, chat: makeChat(container)).modelContainer(container))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            let first = Date.now.timeIntervalSince(start) * 1000
            // Then whatever the screen does once it is up (work started on appearing), until the main thread is free again.
            let settle = Date.now
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let after = Date.now.timeIntervalSince(settle) * 1000 - 50
            print("EZRA-LOAD screen \(name): \(String(format: "%.0f", first + after)) ms (first draw \(String(format: "%.0f", first)), then \(String(format: "%.0f", after)))")
            if name == "Today", let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { Attachment.record(png, named: "load-today.png") }
            }
            // Let go of the screen at once, so it does not redraw in the background while the next one is measured.
            window.contentView = nil
            window.close()
        }
        // The same planner views on an empty store, to tell what the data costs from what the screen costs anyway.
        let (_, empty) = try makeWorkspace()
        for mode in ["day", "week", "month", "year"] {
            UserDefaults.standard.set(mode, forKey: "planner.mode")
            let app = AppModel()
            app.destination = .planner
            let start = Date.now
            let host = NSHostingView(rootView: RootView(container: empty, app: app, chat: makeChat(empty)).modelContainer(empty))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            print("EZRA-LOAD empty Planner \(mode): \(String(format: "%.0f", Date.now.timeIntervalSince(start) * 1000)) ms")
            window.close()
        }
        let service = CalendarService.shared
        let year = try #require(Calendar.current.dateInterval(of: .year, for: .now))
        _ = timed("Apple Calendar: events of one day") { service.events(on: .now) }
        _ = timed("Apple Calendar: events of the year (connected: \(service.isConnected))") { service.events(in: year) }
    }

    /// Draws one planner view over and over, so a profiler can be pointed at the app while it does. Run with TEST_RUNNER_EZRA_PROFILE=<mode>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_PROFILE"] != nil))
    func drawThePlannerRepeatedly() async throws {
        let (workspace, container) = try makeWorkspace()
        try LoadTest.fill(workspace.context, todos: 5000)
        let savedMode = UserDefaults.standard.string(forKey: "planner.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "planner.mode") }
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["EZRA_PROFILE"], forKey: "planner.mode")
        print("EZRA-LOAD profiling starts")
        for _ in 0..<10 {
            let app = AppModel()
            app.destination = .planner
            let host = NSHostingView(rootView: RootView(container: container, app: app, chat: makeChat(container)).modelContainer(container))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            window.close()
        }
    }

    /// How long the app takes to respond to the things a person does all day, on the load data. Run with TEST_RUNNER_EZRA_LOAD=<n>.
    @Test func theEverydayActionsAtScale() async throws {
        let count = Int(ProcessInfo.processInfo.environment["EZRA_LOAD"] ?? "") ?? 5000
        let (workspace, container) = try makeWorkspace()
        try LoadTest.fill(workspace.context, todos: count)
        let app = AppModel()
        app.context = workspace.context
        let host = NSHostingView(rootView: RootView(container: container, app: app, chat: makeChat(container)).modelContainer(container))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        /// Does one thing, then waits for the screen to catch up; reports how long the main thread was busy.
        func act(_ label: String, _ action: () throws -> Void) async throws {
            let start = Date.now
            try action()
            host.layoutSubtreeIfNeeded()
            // Two turns of the run loop, for updates the action only scheduled.
            for _ in 0..<2 {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            print("EZRA-ACT \(label): \(String(format: "%.0f", Date.now.timeIntervalSince(start) * 1000 - 20)) ms")
        }
        let today = try workspace.tasks(in: .today)
        let first = try #require(today.first)
        // For a profiler: the same change over and over. Run with TEST_RUNNER_EZRA_PROFILE=typing or =ticking.
        if let what = ProcessInfo.processInfo.environment["EZRA_PROFILE"] {
            app.open(first)
            host.layoutSubtreeIfNeeded()
            print("EZRA-LOAD profiling starts")
            for round in 0..<(what == "typing" ? 30 : 12) {
                if what == "typing" { first.title += "x" } else { try workspace.setCompleted(today[10 + round], true) }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            window.contentView = nil
            window.close()
            return
        }
        try await act("switch to Upcoming") { app.destination = .list(.upcoming) }
        try await act("switch to Anytime") { app.destination = .list(.anytime) }
        try await act("switch back to Today") { app.destination = .list(.today) }
        try await act("open a to-do") { app.open(first) }
        try await act("type one letter in its title") { first.title += "x" }
        try await act("type another letter") { first.title += "y" }
        try await act("save (what happens a moment after typing)") { try workspace.context.save() }
        try await act("close the to-do") { app.closeCard() }
        try await act("tick a to-do off") { try workspace.setCompleted(today[1], true) }
        try await act("add a to-do") { try workspace.addToDo(title: "New one", schedule: .on(.now)) }
        try await act("open the When picker") { app.pick(.when, for: today[2]) }
        try await act("close it") { app.closePicker() }
        try await act("select three to-dos") { today[3...5].forEach(app.toggleSelection) }
        try await act("clear the selection") { app.clearSelection() }
        try await act("open Quick Find") { app.setQuickFind(true) }
        try await act("close Quick Find") { app.setQuickFind(false) }
        // The Logbook: opened, then the same everyday changes made after it has been visited.
        try await act("open the Logbook") { app.destination = .list(.logbook) }
        try await act("tick a to-do off, Logbook open") { try workspace.setCompleted(today[6], true) }
        try await act("back to Today") { app.destination = .list(.today) }
        try await act("tick a to-do off, after the Logbook") { try workspace.setCompleted(today[7], true) }
        // What a save costs the shared library: as it is now, and when it also keeps every completed to-do
        // (which, before the Logbook was paged, every save did once the Logbook had been opened).
        let library = Library(context: workspace.context)
        try await act("library refresh, open to-dos only") { library.refresh() }
        library.wantDone()
        try await act("library refresh, keeping every completed to-do") { library.refresh() }
        try await act("one Logbook page from the database") { _ = try library.completed(limit: 100) }
        try await act("count the Logbook in the database") { _ = try library.completedCount() }
        try await act("hide the sidebar") { app.setSidebar(hidden: true) }
        try await act("show the sidebar") { app.setSidebar(hidden: false) }
        try await act("go to a project") { app.destination = .project(try #require(try workspace.projects().first)) }
        window.contentView = nil
        window.close()
        UserDefaults.standard.set(false, forKey: AppModel.sidebarKey)
    }
}
