import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Ezra

/// The Quick Entry panel (⌃Space): pictures of it, empty and filled in, light and dark. Run with TEST_RUNNER_EZRA_SNAPSHOTS=1.
@MainActor
struct QuickEntryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZRA_SNAPSHOTS"] == "1"), arguments: ["empty", "filled", "filled-dark", "wrong-date"])
    func quickEntrySnapshot(state: String) async throws {
        let (workspace, container) = try makeWorkspace()
        try workspace.addProject(name: "Checkout API v2")
        let view = QuickEntryView(
            close: {},
            title: state == "empty" ? "" : "Call the bank about the card",
            notes: state == "empty" ? "" : "Ask about the double charge on 3 Nov.",
            when: state == "empty" ? "" : state == "wrong-date" ? "someday soon-ish" : "tomorrow 9am"
        )
        .modelContainer(container)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: state.hasSuffix("dark") ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.setFrameSize(host.fittingSize)
        window.setContentSize(host.fittingSize)
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "quickentry-\(state).png")
    }
}
