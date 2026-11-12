import AppKit
import SwiftData

/// Launch arguments for demos and screenshots:
///   -ResetDemo YES        replace the demo content with a fresh copy
///   -DemoScreen <name>    open on one screen (see `screens`)
///   -DemoTour YES         walk through every screen once
///   -DemoSnapshot YES     save a PNG of the window for each screen shown, in the app's temporary folder
@MainActor
enum DemoScript {
    static let screens = [
        "today", "planner", "inbox", "upcoming", "anytime", "someday", "logbook", "project", "area",
        "event", "card", "new", "when", "deadline", "quickfind", "settings",
    ]

    static func run(app: AppModel, context: ModelContext, defaults: UserDefaults = .standard) async {
        if defaults.bool(forKey: "ResetDemo") {
            do {
                try Seeder.reset(context: context, defaults: defaults)
            } catch {
                Alerts.shared.report("reset the demo data", error)
            }
        }
        let snapshots = defaults.bool(forKey: "DemoSnapshot")
        var queue: [String] = []
        if let screen = defaults.string(forKey: "DemoScreen") { queue.append(screen.lowercased()) }
        if defaults.bool(forKey: "DemoTour") { queue += screens }

        for (index, screen) in queue.enumerated() {
            show(screen, app: app, context: context)
            do {
                try await Task.sleep(for: .seconds(snapshots ? 1.2 : 2.5))
            } catch {
                return // the window closed
            }
            if snapshots { snapshot(named: screen) }
            if index < queue.count - 1 { clearOverlays(app) }
        }
    }

    private static func clearOverlays(_ app: AppModel) {
        app.closeCard()
        app.setQuickFind(false)
    }

    static func show(_ screen: String, app: AppModel, context: ModelContext) {
        let workspace = Workspace(context: context)
        do {
            let sample = try workspace.tasks().first { $0.title == "Buy party decorations" } ?? workspace.tasks().first
            switch screen {
            case "project":
                if let project = try workspace.projects().first(where: { $0.name == "Throw Party for Eve" }) ?? workspace.projects().first {
                    app.destination = .project(project)
                }
            case "area":
                if let area = try workspace.areas().first { app.destination = .area(area) }
            case "card", "when", "deadline":
                app.destination = .list(.today)
                guard let sample else { return }
                app.open(sample)
                if screen != "card" { app.pick(screen == "when" ? .when : .deadline, for: sample) }
            case "event":
                app.destination = .planner
                app.openEvent = try workspace.events().first { Calendar.current.isDateInToday($0.start) && !$0.noteBody.isEmpty }
            case "new":
                app.destination = .list(.today)
                app.newToDo()
            case "quickfind":
                app.setQuickFind(true)
            case "planner":
                app.destination = .planner
            case "assistant":
                app.destination = .assistant
            case "notes":
                app.destination = .special(.allNotes)
            default:
                if let list = SmartList(rawValue: screen) {
                    app.destination = .list(list)
                } else {
                    Log.store.warning("Unknown demo screen \(screen, privacy: .public)")
                }
            }
        } catch {
            Alerts.shared.report("show the demo screen", error)
        }
    }

    /// Draws the app's own window (and its sheet, if one is up) into a PNG. Needs no screen-recording permission.
    private static func snapshot(named name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet != nil })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
        else { return }
        for (suffix, target) in [("", window), ("-sheet", window.attachedSheet)] {
            guard let target, let view = target.contentView?.superview ?? target.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let file = FileManager.default.temporaryDirectory.appending(path: "ezra-\(name)\(suffix).png")
            do {
                guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: file)
                Log.store.info("Saved snapshot \(file.path, privacy: .public)")
            } catch {
                Log.store.error("Snapshot \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
