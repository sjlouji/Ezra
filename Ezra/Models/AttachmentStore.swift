import Foundation
import SwiftData

/// Where the files attached to notes are kept, and the only code that touches them.
/// With a folder chosen in iCloud Drive, iCloud carries the files to the user's other devices;
/// without one they stay inside the app on this Mac.
@MainActor
@Observable
final class AttachmentStore {
    static let shared = AttachmentStore()
    private static let bookmarkKey = "attachments.folderBookmark"

    /// The folder the user chose, if any.
    private(set) var chosenFolder: URL?
    private let localFolder: URL

    init(localFolder: URL = URL.applicationSupportDirectory.appending(path: "Attachments"), restoresChoice: Bool = true) {
        self.localFolder = localFolder
        guard restoresChoice, let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var isStale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            chosenFolder = folder
        } catch {
            Log.store.error("The chosen attachments folder could not be reopened: \(String(describing: error), privacy: .public)")
            Alerts.shared.message = "Ezra can no longer reach the folder you chose for attachments. Choose it again in Settings."
        }
    }

    var folder: URL { chosenFolder ?? localFolder }

    /// Remembers a folder the user picked and moves the files gathered so far into it.
    func choose(_ picked: URL) throws {
        guard picked.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        let bookmark = try picked.bookmarkData(options: .withSecurityScope)
        try use(picked)
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
    }

    /// Switches to `newFolder`, moving every file from the current folder; a file already there is left as it is.
    func use(_ newFolder: URL) throws {
        let files = FileManager.default
        let old = folder
        try files.createDirectory(at: newFolder, withIntermediateDirectories: true)
        if old != newFolder, files.fileExists(atPath: old.path) {
            for name in try files.contentsOfDirectory(atPath: old.path) where !files.fileExists(atPath: newFolder.appending(path: name).path) {
                try files.moveItem(at: old.appending(path: name), to: newFolder.appending(path: name))
            }
        }
        chosenFolder = newFolder
    }

    func url(for attachment: Attachment) -> URL {
        folder.appending(path: attachment.storedName)
    }

    /// False while the file has not reached this device yet (or was removed from the folder by hand).
    func hasFile(for attachment: Attachment) -> Bool {
        FileManager.default.fileExists(atPath: url(for: attachment).path)
    }

    /// Copies a file into the attachments folder and records it on the note.
    @discardableResult
    func attach(fileAt source: URL, to note: Note, in context: ModelContext) throws -> Attachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let attachment = Attachment(filename: source.lastPathComponent, byteCount: size)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url(for: attachment))
        context.insert(attachment)
        attachment.note = note
        note.updatedAt = .now
        try context.save()
        return attachment
    }

    /// Removes the attachment and its file.
    func remove(_ attachment: Attachment, in context: ModelContext) throws {
        let file = url(for: attachment)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        attachment.note?.updatedAt = .now
        context.delete(attachment)
        try context.save()
    }
}
