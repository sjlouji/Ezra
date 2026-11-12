import AppKit
import Foundation
import SwiftData

/// Keeps this device's database and the user's Firestore in step: sends what changed here, applies what changed elsewhere.
@MainActor
@Observable
final class SyncEngine {
    enum Status: Equatable {
        /// No GoogleService-Info.plist in the app.
        case unavailable
        case signedOut
        case idle(lastSync: Date?)
        case failed(String)
    }

    /// What this device remembers between runs: how far it has read, and the fingerprint of each item as last sent or received.
    private struct State: Codable {
        var uid = ""
        var cursor: SyncCursor?
        var known: [String: String] = [:]
    }

    private static let deletedMark = "deleted"

    private(set) var status: Status
    private(set) var email: String?

    private let container: ModelContainer
    private let auth: FirebaseAuthClient?
    private let firestore: FirestoreClient?
    private let reminders: ReminderScheduler?
    private let deviceID: String
    private let stateURL: URL
    private let writeSession: (Data?) throws -> Void
    private var session: AuthSession?
    private var state = State()
    private var isSyncing = false
    private var hasUnsentChanges = true
    private var lastSync = Date.distantPast
    private var loop: Task<Void, Never>?
    private var saveObserver: NSObjectProtocol?

    init(
        container: ModelContainer,
        config: FirebaseConfig? = .load(),
        transport: @escaping Transport = HTTP.live,
        reminders: ReminderScheduler? = .shared,
        deviceID: String? = nil,
        stateURL: URL = URL.applicationSupportDirectory.appending(path: "sync-state.json"),
        readSession: () throws -> Data? = { try Keychain.read(Keychain.syncSession) },
        writeSession: @escaping (Data?) throws -> Void = { try Keychain.write($0, Keychain.syncSession) }
    ) {
        self.container = container
        self.auth = config.map { FirebaseAuthClient(config: $0, transport: transport) }
        self.firestore = config.map { FirestoreClient(config: $0, transport: transport) }
        self.reminders = reminders
        self.stateURL = stateURL
        self.writeSession = writeSession
        if let deviceID {
            self.deviceID = deviceID
        } else if let stored = UserDefaults.standard.string(forKey: "sync.device") {
            self.deviceID = stored
        } else {
            self.deviceID = UUID().uuidString
            UserDefaults.standard.set(self.deviceID, forKey: "sync.device")
        }
        status = config == nil ? .unavailable : .signedOut
        do {
            try SyncStore(context: container.mainContext).repairIdentifiers()
            if let stored = try readSession() {
                session = try JSONDecoder().decode(AuthSession.self, from: stored)
            }
            if let saved = try? Data(contentsOf: stateURL) { // no file yet on a first run
                state = try JSONDecoder().decode(State.self, from: saved)
            }
        } catch {
            Log.sync.error("Could not restore sync: \(String(describing: error), privacy: .public)")
            status = .failed("Could not restore the saved sign-in. \(error.localizedDescription)")
        }
        if let session, config != nil, status == .signedOut {
            email = session.email
            status = .idle(lastSync: nil)
        }
    }

    var isSignedIn: Bool { session != nil }

    /// Syncs soon after every local save, and otherwise every few seconds while the app is in front (every minute when it is not).
    func start() {
        guard loop == nil, auth != nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hasUnsentChanges = true }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.session != nil {
                    let interval: TimeInterval = NSApp?.isActive == true ? 4 : 60
                    if self.hasUnsentChanges || Date.now.timeIntervalSince(self.lastSync) >= interval {
                        await self.syncNow()
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func signIn(email: String, password: String) async {
        guard let auth else { return status = .unavailable }
        do {
            let fresh = try await auth.signIn(email: email.trimmed, password: password)
            try writeSession(try JSONEncoder().encode(fresh))
            if state.uid != fresh.uid { state = State(uid: fresh.uid) } // another account: start its sync from nothing
            (session, self.email, status) = (fresh, fresh.email, .idle(lastSync: nil))
            Log.sync.info("Signed in for sync")
            await syncNow()
        } catch {
            fail("sign in", error)
        }
    }

    /// Stops syncing on this device. Local data stays; so does what is in Firestore.
    func signOut() {
        do {
            try writeSession(nil)
            if FileManager.default.fileExists(atPath: stateURL.path) { try FileManager.default.removeItem(at: stateURL) }
            (session, email, state, status) = (nil, nil, State(), .signedOut)
        } catch {
            fail("sign out", error)
        }
    }

    func syncNow() async {
        guard let auth, let firestore, let signedIn = session, !isSyncing else { return }
        isSyncing = true
        hasUnsentChanges = false
        defer { isSyncing = false }
        do {
            let current = try await auth.current(signedIn)
            if current != signedIn {
                try writeSession(try JSONEncoder().encode(current))
                session = current
            }
            let store = SyncStore(context: container.mainContext)

            // Items edited, added or deleted here since they were last sent keep the local version.
            let before = try store.snapshot()
            let present = Set(before.map(\.id))
            var unsent = Set(before.filter { state.known[$0.id] != $0.fingerprint }.map(\.id))
            unsent.formUnion(state.known.filter { $0.value != Self.deletedMark && !present.contains($0.key) }.keys)

            let arrived = try await firestore.changes(after: state.cursor, session: current)
            let fromOthers = arrived.filter { $0.device != deviceID }
            try store.apply(fromOthers, skipping: unsent, reminders: reminders)

            let after = try store.snapshot()
            let fingerprints = Dictionary(after.map { ($0.id, $0.fingerprint) }) { first, _ in first }
            for item in fromOthers where !unsent.contains(item.id) {
                state.known[item.id] = item.deleted ? Self.deletedMark : fingerprints[item.id] ?? Self.deletedMark
            }
            if let last = arrived.last { state.cursor = SyncCursor(updatedAt: last.updatedAt, name: last.name) }

            var outgoing = after.filter { state.known[$0.id] != $0.fingerprint }
                .map { OutgoingItem(id: $0.id, kind: $0.kind.rawValue, deleted: false, payload: $0.payload) }
            let removed = state.known.filter { $0.value != Self.deletedMark && fingerprints[$0.key] == nil }.keys
            outgoing += removed.map { OutgoingItem(id: $0, kind: Self.deletedMark, deleted: true, payload: "") }
            if !outgoing.isEmpty {
                try await firestore.commit(outgoing, device: deviceID, session: current)
                for item in outgoing {
                    state.known[item.id] = item.deleted ? Self.deletedMark : fingerprints[item.id] ?? Self.deletedMark
                }
                Log.sync.info("Sent \(outgoing.count) items, received \(fromOthers.count)")
            }
            state.uid = current.uid
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            lastSync = .now
            status = .idle(lastSync: lastSync)
        } catch {
            lastSync = .now // wait a full interval before trying again
            hasUnsentChanges = true
            fail("sync", error)
        }
    }

    private func fail(_ action: String, _ error: Error) {
        Log.sync.error("Could not \(action, privacy: .public): \(String(describing: error), privacy: .public)")
        status = .failed("Could not \(action). \(error.localizedDescription)")
    }
}
