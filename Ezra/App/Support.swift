import OSLog
import SwiftUI

enum Log {
    private static let subsystem = "app.ezra.Ezra"
    static let store = Logger(subsystem: subsystem, category: "store")
    static let reminders = Logger(subsystem: subsystem, category: "reminders")
    static let assistant = Logger(subsystem: subsystem, category: "assistant")
    static let sync = Logger(subsystem: subsystem, category: "sync")
}

/// The one place a failed user action is logged and put in front of the user.
@MainActor
@Observable
final class Alerts {
    static let shared = Alerts()
    var message: String?
    /// A place in System Settings that fixes what `message` describes; the alert offers a button to it.
    var settingsLink: (label: String, url: URL)?

    func attempt(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            report(action, error)
        }
    }

    func report(_ action: String, _ error: Error) {
        Log.store.error("Could not \(action, privacy: .public): \(String(describing: error), privacy: .public)")
        message = "Could not \(action). \(error.localizedDescription)"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Optional where Wrapped == String {
    /// The on-device model often sends "" for an argument it means to leave out.
    var nonEmpty: String? {
        guard let text = self?.trimmed, !text.isEmpty else { return nil }
        return text
    }
}
