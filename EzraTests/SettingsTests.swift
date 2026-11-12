import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Ezra

@MainActor
struct SettingsTests {
    @Test func theDockIconFollowsAppearanceTimeAndTheUsersChoice() {
        #expect(DockIcon.assetName(dark: false, scene: .automatic, hour: 6) == "Icon-light-day")
        #expect(DockIcon.assetName(dark: false, scene: .automatic, hour: 17) == "Icon-light-day")
        #expect(DockIcon.assetName(dark: false, scene: .automatic, hour: 18) == "Icon-light-night")
        #expect(DockIcon.assetName(dark: true, scene: .automatic, hour: 5) == "Icon-dark-night")
        #expect(DockIcon.assetName(dark: true, scene: .day, hour: 23) == "Icon-dark-day")
        #expect(DockIcon.assetName(dark: false, scene: .night, hour: 12) == "Icon-light-night")
        for name in ["Icon-light-day", "Icon-light-night", "Icon-dark-day", "Icon-dark-night"] {
            #expect(NSImage(named: name) != nil, "\(name) is missing from the app")
        }
    }

    /// Each Settings tab, rendered. Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"), arguments: ["general", "sync", "assistant", "quickentry", "reminders", "calendar"])
    func settingsSnapshot(pane: String) async throws {
        let (workspace, container) = try makeWorkspace()
        try Seeder.seed(context: workspace.context, defaults: try #require(UserDefaults(suiteName: "ezra.tests.\(UUID().uuidString)")))
        let chat = makeChat(container, transport: FakeClaude([(200, #"{"models": [{"name": "qwen3:14b"}, {"name": "mistral:latest"}]}"#)]).transport)
        let view: AnyView = switch pane {
        case "general": AnyView(GeneralPane())
        case "sync": AnyView(SyncPane(sync: nil))
        case "assistant": AnyView(AssistantPane(chat: chat))
        case "quickentry": AnyView(QuickEntryPane())
        case "reminders": AnyView(RemindersPane())
        default: AnyView(CalendarPane())
        }
        let host = NSHostingView(rootView: view.frame(width: 620).fixedSize(horizontal: false, vertical: true).modelContainer(container))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        // Closing a window made in code releases it unless told not to; the test still holds it, so it would be released twice.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "settings-\(pane).png")
    }
}
