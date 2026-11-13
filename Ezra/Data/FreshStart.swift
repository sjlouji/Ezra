import Foundation
import UserNotifications

/// Puts Ezra on this Mac back to how it is when first installed: no to-dos, projects or notes, default settings, signed
/// out of sync. Asked for only on the command line (`-EraseAllDataOnThisMac YES`) and done before anything is opened,
/// so nothing is running that could pass the removals on to the user's other devices. What is kept in the cloud stays.
@MainActor
enum FreshStart {
    static let argument = "EraseAllDataOnThisMac"
    /// Settings that survive: whether Claude may use Ezra. That was set up outside Ezra as well, and would break.
    static let kept = [MCPServer.enabledKey]
    /// The files of one store: the store itself, the two SQLite keeps beside it, and the folder SwiftData keeps large values in.
    static func files(of store: URL) -> [URL] {
        let folder = store.deletingLastPathComponent(), name = store.deletingPathExtension().lastPathComponent
        return ["", "-shm", "-wal"].map { URL(fileURLWithPath: store.path + $0) } + [folder.appending(path: ".\(name)_SUPPORT")]
    }

    /// Given with the argument above (`-WithoutDemoContent YES`): start with nothing at all, not with the demo content.
    static let emptyArgument = "WithoutDemoContent"

    /// True only when this launch was started with the argument; a saved setting of the same name does nothing.
    static var requested: Bool { given(argument) }
    static var withoutDemo: Bool { given(emptyArgument) }

    private static func given(_ name: String) -> Bool {
        let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[name]
        return (value as? String).map { ["YES", "TRUE", "1"].contains($0.uppercased()) } ?? false
    }

    /// `stores` are asked for where they really are: with the widgets' shared folder in play, that is not the app's own
    /// Application Support folder, which is why the places are not written down here.
    static func erase(
        stores: [URL] = [EzraStore.storeURL(), EzraStore.storeURL(named: LoadTest.storeName)],
        attachments: URL = URL.applicationSupportDirectory.appending(path: "Attachments"),
        defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier, withoutDemo: Bool = false,
        forget: (String) throws -> Void = { try Keychain.write(nil, $0) }
    ) throws {
        for file in stores.flatMap(files) + [attachments] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        // Signed out of sync, so a fresh start is not filled again from the cloud. The keys for Claude are kept.
        try forget(Keychain.syncSession)
        let surviving = kept.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }
        if let domain { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in surviving { defaults.set(value, forKey: key) }
        // The demo content is put in on a first launch; noting that it has been keeps it out.
        if withoutDemo {
            defaults.set(true, forKey: Seeder.seededKey)
            defaults.set(Seeder.version, forKey: Seeder.versionKey)
        }
        Log.store.notice("Ezra's data on this Mac was erased at launch, as asked on the command line")
    }

    /// Reminders set for to-dos that are gone would still ring.
    static func clearReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
