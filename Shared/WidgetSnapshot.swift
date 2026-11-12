import Foundation

/// What the desktop widgets show. The app writes it whenever the data changes; the widgets only read it,
/// from a folder both are allowed into.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        /// Where it belongs: its project or area; empty for neither.
        var place: String
        /// The day it is planned for; nil for today's own list.
        var day: Date?
        var isDue: Bool
    }

    var updated: Date
    var today: [Item]
    /// The next days' to-dos, soonest first.
    var upcoming: [Item]

    static let group = "Z7V2UFGTCB.app.ezra.Ezra"

    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(path: "widgets.json")
    }

    static func read() throws -> WidgetSnapshot {
        guard let file else { throw CocoaError(.fileReadNoPermission) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetSnapshot.self, from: try Data(contentsOf: file))
    }

    func write() throws {
        guard let file = Self.file else { throw CocoaError(.fileWriteNoPermission) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
