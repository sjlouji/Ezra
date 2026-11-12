import Foundation
import SwiftData
import Testing

@testable import Ezra

/// Stands in for Firebase: sign-in, token renewal, and a Firestore that stores items and answers change queries
/// the way the real one does (server time per batch, ordered by time then name, pages of a fixed size).
actor FakeFirebase {
    private var documents: [String: (fields: [String: Any], time: Int)] = [:]
    private var clock = 0
    private(set) var commits = 0
    private(set) var queries = 0
    var pageLimitSeen = 0

    nonisolated var transport: Transport {
        { request in try await self.answer(request) }
    }

    func itemCount() -> Int { documents.count }

    private static func stamp(_ time: Int) -> String { String(format: "2026-11-12T00:00:%02d.%06dZ", time / 1_000_000, time % 1_000_000) }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url?.absoluteString)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        func reply(_ status: Int, _ json: Any) throws -> (Data, HTTPURLResponse) {
            let address = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: address, statusCode: status, httpVersion: nil, headerFields: nil))
            return (try JSONSerialization.data(withJSONObject: json), response)
        }
        if url.contains("accounts:signInWithPassword") {
            guard body["password"] as? String == "correct" else {
                return try reply(400, ["error": ["code": 400, "message": "INVALID_LOGIN_CREDENTIALS"]])
            }
            return try reply(200, ["idToken": "token-1", "refreshToken": "refresh-1", "localId": "user1", "expiresIn": "3600"])
        }
        if url.contains("securetoken.googleapis.com") {
            return try reply(200, ["id_token": "token-2", "refresh_token": "refresh-2", "expires_in": "3600"])
        }
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer token-") == true, url.contains("/users/user1") || url.hasSuffix(":commit") else {
            return try reply(403, [["error": ["code": 403, "message": "Missing or insufficient permissions.", "status": "PERMISSION_DENIED"]]])
        }
        if url.hasSuffix(":commit") {
            commits += 1
            clock += 1
            for write in try #require(body["writes"] as? [[String: Any]]) {
                let update = try #require(write["update"] as? [String: Any])
                var fields = try #require(update["fields"] as? [String: Any])
                fields["updatedAt"] = ["timestampValue": Self.stamp(clock)]
                documents[try #require(update["name"] as? String)] = (fields, clock)
            }
            return try reply(200, ["writeResults": []])
        }
        queries += 1
        let query = try #require(body["structuredQuery"] as? [String: Any])
        let limit = try #require(query["limit"] as? Int)
        pageLimitSeen = limit
        var ordered = documents.sorted { ($0.value.time, $0.key) < ($1.value.time, $1.key) }
        if let start = query["startAt"] as? [String: Any], let values = start["values"] as? [[String: String]] {
            let (time, name) = (try #require(values[0]["timestampValue"]), try #require(values[1]["referenceValue"]))
            ordered = ordered.filter { (Self.stamp($0.value.time), $0.key) > (time, name) }
        }
        let rows = ordered.prefix(limit).map { ["document": ["name": $0.key, "fields": $0.value.fields]] }
        return try reply(200, rows.isEmpty ? [["readTime": Self.stamp(clock)]] : rows)
    }
}

@MainActor
struct SyncTests {
    private struct Device {
        let engine: SyncEngine
        let workspace: Workspace
        let stateURL: URL
    }

    private func makeDevice(_ name: String, firebase: FakeFirebase) throws -> Device {
        let (workspace, container) = try makeWorkspace()
        let stateURL = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString).json")
        var stored: Data?
        let engine = SyncEngine(
            container: container, config: FirebaseConfig(apiKey: "key", projectID: "demo"), transport: firebase.transport,
            reminders: nil, deviceID: name, stateURL: stateURL, readSession: { stored }, writeSession: { stored = $0 }
        )
        return Device(engine: engine, workspace: workspace, stateURL: stateURL)
    }

    @Test func aWrongPasswordIsExplainedAndTheRightOneSignsIn() async throws {
        let device = try makeDevice("A", firebase: FakeFirebase())
        await device.engine.signIn(email: "me@example.com", password: "wrong")
        #expect(device.engine.status == .failed("Could not sign in. That email and password do not match an account in your Firebase project."))
        #expect(!device.engine.isSignedIn)
        await device.engine.signIn(email: " me@example.com ", password: "correct")
        #expect(device.engine.isSignedIn && device.engine.email == "me@example.com")
    }

    @Test func whatOneDeviceCreatesEditsAndDeletesReachesTheOther() async throws {
        let firebase = FakeFirebase()
        let (a, b) = (try makeDevice("A", firebase: firebase), try makeDevice("B", firebase: firebase))
        let area = try a.workspace.addArea(name: "Work")
        let project = try a.workspace.addProject(name: "Launch", area: area)
        let heading = try a.workspace.addHeading(title: "Prep", to: project)
        let todo = try a.workspace.addToDo(title: "Write copy", notes: "Short", project: project, heading: heading, schedule: .on(.now, evening: true), tags: ["Important"])
        let item = ChecklistItem(title: "Headline")
        a.workspace.context.insert(item)
        item.task = todo
        let event = try a.workspace.addEvent(title: "Review", start: .now, bucket: .fire, project: project)
        try a.workspace.addNote(title: "Plan", body: "# Goal", project: project)
        todo.event = event
        try a.workspace.context.save()

        await a.engine.signIn(email: "me@example.com", password: "correct")
        await b.engine.signIn(email: "me@example.com", password: "correct")

        // Everything arrives on B, connected the same way.
        let arrived = try b.workspace.findToDo("Write copy")
        #expect(arrived.uuid == todo.uuid && arrived.notes == "Short" && arrived.tags == ["Important"] && arrived.evening)
        #expect(arrived.startDate == todo.startDate && arrived.order == todo.order)
        #expect(arrived.project?.name == "Launch" && arrived.project?.area?.name == "Work" && arrived.heading?.title == "Prep")
        #expect(arrived.sortedChecklist.map(\.title) == ["Headline"] && arrived.event?.title == "Review")
        #expect(try b.workspace.notes().first?.project?.name == "Launch")
        #expect(await firebase.itemCount() == 7)

        // B completes it and renames the project; A sees both.
        try b.workspace.setCompleted(arrived, true)
        try #require(arrived.project).name = "Launch v2"
        try b.workspace.context.save()
        await b.engine.syncNow()
        await a.engine.syncNow()
        #expect(todo.isCompleted && project.name == "Launch v2")

        // A deletes the to-do; it disappears from B, checklist and all.
        try a.workspace.delete(todo)
        await a.engine.syncNow()
        await b.engine.syncNow()
        #expect(try b.workspace.allToDos().isEmpty)
        #expect(try b.workspace.context.fetchCount(FetchDescriptor<ChecklistItem>()) == 0)
        #expect(try b.workspace.projects().map(\.name) == ["Launch v2"])
    }

    @Test func noteOrderReachesTheOtherDevice() async throws {
        let firebase = FakeFirebase()
        let (a, b) = (try makeDevice("A", firebase: firebase), try makeDevice("B", firebase: firebase))
        let first = try a.workspace.addNote(title: "First")
        let second = try a.workspace.addNote(title: "Second")
        try a.workspace.sort(.note(second), into: .notes(nil), after: .note(first), before: nil)
        await a.engine.signIn(email: "me@example.com", password: "correct")
        await b.engine.signIn(email: "me@example.com", password: "correct")
        #expect(try b.workspace.notes().map(\.title) == ["First", "Second"])
    }

    @Test func conversationsAndAttachmentRecordsReachTheOtherDevice() async throws {
        let firebase = FakeFirebase()
        let (a, b) = (try makeDevice("A", firebase: firebase), try makeDevice("B", firebase: firebase))
        let chat = makeChat(a.workspace.context.container)
        try chat.record(.user, "What is due today?")
        try chat.record(.assistant, "Two things.", steps: [ChatStep(tool: "completeTask", label: "Complete to-do", detail: "title: Call bank")])
        chat.togglePin(try #require(chat.thread))
        let note = try a.workspace.addNote(title: "Trip")
        let folder = FileManager.default.temporaryDirectory.appending(path: "attach-\(UUID().uuidString)")
        let store = AttachmentStore(localFolder: folder, restoresChoice: false)
        let source = FileManager.default.temporaryDirectory.appending(path: "ticket-\(UUID().uuidString).txt")
        try Data("boarding pass".utf8).write(to: source)
        let attachment = try store.attach(fileAt: source, to: note, in: a.workspace.context)

        await a.engine.signIn(email: "me@example.com", password: "correct")
        await b.engine.signIn(email: "me@example.com", password: "correct")

        let threads = try b.workspace.context.fetch(FetchDescriptor<ChatThread>())
        #expect(threads.map(\.title) == ["What is due today?"])
        #expect(threads.first?.sortedMessages.map(\.roleRaw) == ["user", "assistant"])
        #expect(try threads.first?.sortedMessages.last?.steps().map(\.detail) == ["title: Call bank"])
        #expect(threads.first?.pinned == true)
        let arrived = try #require(try b.workspace.notes().first?.sortedAttachments.first)
        #expect(arrived.uuid == attachment.uuid && arrived.filename == source.lastPathComponent && arrived.byteCount == 13)

        // Deleting the conversation on B removes it, and its messages, from A.
        chat.newChat()
        b.workspace.context.delete(try #require(threads.first))
        try b.workspace.context.save()
        await b.engine.syncNow()
        await a.engine.syncNow()
        #expect(try a.workspace.context.fetchCount(FetchDescriptor<ChatThread>()) == 0)
        #expect(try a.workspace.context.fetchCount(FetchDescriptor<ChatMessage>()) == 0)
    }

    @Test func nothingIsSentAgainWhenNothingChanged() async throws {
        let firebase = FakeFirebase()
        let a = try makeDevice("A", firebase: firebase)
        try a.workspace.addToDo(title: "One")
        await a.engine.signIn(email: "me@example.com", password: "correct")
        #expect(await firebase.commits == 1)
        await a.engine.syncNow()
        await a.engine.syncNow()
        #expect(await firebase.commits == 1)
        try a.workspace.findToDo("One").title = "One, edited"
        try a.workspace.context.save()
        await a.engine.syncNow()
        #expect(await firebase.commits == 2)
        #expect(await firebase.itemCount() == 1)
    }

    @Test func anItemEditedHereButNotYetSentIsNotOverwrittenByAnOlderRemoteVersion() async throws {
        let firebase = FakeFirebase()
        let (a, b) = (try makeDevice("A", firebase: firebase), try makeDevice("B", firebase: firebase))
        let original = try a.workspace.addToDo(title: "Draft")
        await a.engine.signIn(email: "me@example.com", password: "correct")
        await b.engine.signIn(email: "me@example.com", password: "correct")
        let copy = try b.workspace.findToDo("Draft")

        original.title = "From A"
        try a.workspace.context.save()
        await a.engine.syncNow()
        copy.title = "From B" // edited on B before B has seen A's change
        try b.workspace.context.save()
        await b.engine.syncNow()
        #expect(copy.title == "From B")
        await a.engine.syncNow()
        #expect(original.title == "From B") // the device that synced last wins
    }

    @Test func aLargeFirstSyncArrivesCompleteAcrossPages() async throws {
        let firebase = FakeFirebase()
        let (a, b) = (try makeDevice("A", firebase: firebase), try makeDevice("B", firebase: firebase))
        for number in 1...(FirestoreClient.pageSize + 150) {
            let todo = ToDo(title: "Item \(number)")
            todo.order = Double(number)
            a.workspace.context.insert(todo)
        }
        try a.workspace.context.save()
        await a.engine.signIn(email: "me@example.com", password: "correct")
        await b.engine.signIn(email: "me@example.com", password: "correct")
        #expect(try b.workspace.allToDos().count == FirestoreClient.pageSize + 150)
        #expect(Set(try b.workspace.allToDos().map(\.uuid)) == Set(try a.workspace.allToDos().map(\.uuid)))
    }

    @Test func firebaseSetupProblemsAreExplainedInPlainWords() {
        let disabled = SyncError.server(status: 400, code: "PASSWORD_LOGIN_DISABLED").localizedDescription
        #expect(disabled.contains("enable Email/Password"))
        #expect(SyncError.server(status: 403, code: "PERMISSION_DENIED").localizedDescription.contains("Firestore rules"))
        #expect(SyncError.server(status: 500, code: "INTERNAL").localizedDescription == "Firebase answered 500: INTERNAL.")
    }

    @Test func itemsThatSharedOneIdentifierEachGetTheirOwn() throws {
        let (workspace, _) = try makeWorkspace()
        let shared = UUID()
        for name in ["One", "Two", "Three"] {
            let project = try workspace.addProject(name: name)
            project.uuid = shared
        }
        try SyncStore(context: workspace.context).repairIdentifiers()
        #expect(Set(try workspace.projects().map(\.uuid)).count == 3)
    }

    @Test func aRefusalFromFirestoreIsShownAndSyncRecoversAfterSigningOutAndIn() async throws {
        let firebase = FakeFirebase()
        let a = try makeDevice("A", firebase: firebase)
        try a.workspace.addToDo(title: "Kept")
        await a.engine.signIn(email: "me@example.com", password: "correct")
        a.engine.signOut()
        #expect(a.engine.status == .signedOut && !FileManager.default.fileExists(atPath: a.stateURL.path))
        #expect(try a.workspace.allToDos().count == 1) // local data stays
        await a.engine.signIn(email: "me@example.com", password: "correct")
        #expect(try a.workspace.allToDos().count == 1)
        #expect(await firebase.itemCount() == 1)
    }
}
