import Foundation

/// One item as Firestore holds it: an opaque payload plus what sync needs to order and route it.
struct RemoteItem: Equatable, Sendable {
    let id: String
    let kind: String
    let deleted: Bool
    let payload: String
    /// Which device wrote it.
    let device: String
    /// When the server stored it, and the document's full name: together, its place in the change order.
    let updatedAt: String
    let name: String
}

/// How far through the server's change order a device has read.
struct SyncCursor: Codable, Equatable, Sendable {
    var updatedAt: String
    var name: String
}

/// What to send up for one item.
struct OutgoingItem: Equatable, Sendable {
    let id: String
    let kind: String
    let deleted: Bool
    let payload: String
}

/// The user's items in Firestore, at users/{uid}/items/{id}.
struct FirestoreClient: Sendable {
    let config: FirebaseConfig
    let transport: Transport
    static let pageSize = 300

    private var database: String { "projects/\(config.projectID)/databases/(default)" }
    private var root: String { "https://firestore.googleapis.com/v1/\(database)/documents" }

    /// Every item stored after `cursor`, oldest first.
    func changes(after cursor: SyncCursor?, session: AuthSession) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        var position = cursor
        while true {
            var query: [String: Any] = [
                "from": [["collectionId": "items"]],
                // The document name breaks ties: every write in one batch carries the same server time.
                "orderBy": [
                    ["field": ["fieldPath": "updatedAt"], "direction": "ASCENDING"],
                    ["field": ["fieldPath": "__name__"], "direction": "ASCENDING"],
                ],
                "limit": Self.pageSize,
            ]
            if let position {
                query["startAt"] = [
                    "values": [["timestampValue": position.updatedAt], ["referenceValue": position.name]],
                    "before": false,
                ]
            }
            let request = try HTTP.post(
                "\(root)/users/\(session.uid):runQuery", json: ["structuredQuery": query],
                headers: ["Authorization": "Bearer \(session.idToken)"]
            )
            guard let rows = try await HTTP.json(request, via: transport) as? [[String: Any]] else {
                throw SyncError.unreadableResponse
            }
            let page = rows.compactMap { ($0["document"] as? [String: Any]).flatMap(Self.item) }
            items += page
            guard page.count == Self.pageSize, let last = page.last else { return items }
            position = SyncCursor(updatedAt: last.updatedAt, name: last.name)
        }
    }

    /// Stores the items, each stamped with the server's time. Up to 200 go in one all-or-nothing batch.
    func commit(_ items: [OutgoingItem], device: String, session: AuthSession) async throws {
        for start in stride(from: 0, to: items.count, by: 200) {
            let writes = items[start..<min(start + 200, items.count)].map { item -> [String: Any] in
                [
                    "update": [
                        "name": "\(database)/documents/users/\(session.uid)/items/\(item.id)",
                        "fields": [
                            "kind": ["stringValue": item.kind],
                            "deleted": ["booleanValue": item.deleted],
                            "payload": ["stringValue": item.payload],
                            "device": ["stringValue": device],
                        ],
                    ],
                    "updateTransforms": [["fieldPath": "updatedAt", "setToServerValue": "REQUEST_TIME"]],
                ]
            }
            let request = try HTTP.post(
                "\(root):commit", json: ["writes": writes], headers: ["Authorization": "Bearer \(session.idToken)"]
            )
            _ = try await HTTP.json(request, via: transport)
        }
    }

    private static func item(_ document: [String: Any]) -> RemoteItem? {
        guard let name = document["name"] as? String, let fields = document["fields"] as? [String: [String: Any]],
              let kind = fields["kind"]?["stringValue"] as? String,
              let updatedAt = fields["updatedAt"]?["timestampValue"] as? String
        else { return nil }
        return RemoteItem(
            id: name.split(separator: "/").last.map(String.init) ?? name, kind: kind,
            deleted: fields["deleted"]?["booleanValue"] as? Bool ?? false,
            payload: fields["payload"]?["stringValue"] as? String ?? "",
            device: fields["device"]?["stringValue"] as? String ?? "",
            updatedAt: updatedAt, name: name
        )
    }
}
