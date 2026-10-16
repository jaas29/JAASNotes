import CoreData
import Foundation

/// The single writer for one library. Each mutation runs in one transaction on a private-queue context and
/// is saved to the persistent store before it returns. Callers receive value snapshots only.
actor LibraryRepository: NoteStore {
    static let defaultFolderName = "Notes"
    static let currentFormatVersion = 3

    private let context: NSManagedObjectContext
    private let now: @Sendable () -> Date

    init(container: NSPersistentContainer, now: @escaping @Sendable () -> Date = { Date() }) {
        self.context = container.newBackgroundContext()
        self.now = now
    }

    /// Creates the metadata record and the default Notes folder in one save. A second call returns the
    /// existing metadata and changes nothing. Inconsistent partial data is reported, never repaired.
    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot {
        try await write { context, now in
            let metadata = try Self.fetch(LibraryMetadataRecord.self, entity: "LibraryMetadata", in: context)
            let folders = try Self.fetch(FolderRecord.self, entity: "Folder", in: context)

            switch metadata.count {
            case 1:
                let defaultCount = folders.filter(\.isDefault).count
                guard defaultCount == 1 else {
                    throw LibraryError.libraryInconsistent("Expected one default folder, found \(defaultCount).")
                }
                return LibraryMetadataSnapshot(record: metadata[0])

            case 0:
                guard folders.isEmpty else {
                    throw LibraryError.libraryInconsistent("Folders exist without library metadata.")
                }
                let record = Self.insert(LibraryMetadataRecord.self, entity: "LibraryMetadata", in: context)
                record.libraryID = UUID()
                record.createdAt = now
                record.formatVersion = Int32(Self.currentFormatVersion)

                let folder = Self.insert(FolderRecord.self, entity: "Folder", in: context)
                folder.id = UUID()
                folder.name = Self.defaultFolderName
                folder.normalizedName = FolderName.normalize(Self.defaultFolderName)
                folder.createdAt = now
                folder.modifiedAt = now
                folder.isDefault = true

                return LibraryMetadataSnapshot(record: record)

            default:
                throw LibraryError.libraryInconsistent("Found \(metadata.count) library metadata records.")
            }
        }
    }

    func libraryMetadata() async throws -> LibraryMetadataSnapshot? {
        try await read { context in
            try Self.fetch(LibraryMetadataRecord.self, entity: "LibraryMetadata", in: context)
                .first
                .map(LibraryMetadataSnapshot.init(record:))
        }
    }

    /// Default folder first, then alphabetical by normalized name.
    func folders() async throws -> [FolderSnapshot] {
        try await read { context in
            try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                sortBy: [
                    NSSortDescriptor(key: "isDefault", ascending: false),
                    NSSortDescriptor(key: "normalizedName", ascending: true),
                ]
            )
            .map(FolderSnapshot.init(record:))
        }
    }

    func createFolder(named input: String) async throws -> FolderSnapshot {
        let (displayName, normalizedName) = try FolderName.validated(input)
        return try await write { context, now in
            let duplicates = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "normalizedName == %@", normalizedName)
            )
            guard duplicates.isEmpty else { throw LibraryError.duplicateFolderName }

            let folder = Self.insert(FolderRecord.self, entity: "Folder", in: context)
            folder.id = UUID()
            folder.name = displayName
            folder.normalizedName = normalizedName
            folder.createdAt = now
            folder.modifiedAt = now
            folder.isDefault = false
            return FolderSnapshot(record: folder)
        }
    }

    /// Renames a user folder. The default Notes folder is fixed. Renaming to the same spelling changes nothing.
    func renameFolder(id: UUID, to input: String) async throws -> FolderSnapshot {
        let (displayName, normalizedName) = try FolderName.validated(input)
        return try await write { context, now in
            guard let folder = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "id == %@", id as NSUUID)
            ).first else {
                throw LibraryError.folderNotFound(id)
            }
            guard !folder.isDefault else { throw LibraryError.defaultFolderIsFixed }

            let duplicates = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "normalizedName == %@ AND id != %@", normalizedName, id as NSUUID)
            )
            guard duplicates.isEmpty else { throw LibraryError.duplicateFolderName }

            if !Self.sameScalars(folder.name, displayName) {
                folder.name = displayName
                folder.normalizedName = normalizedName
                folder.modifiedAt = now
            }
            return FolderSnapshot(record: folder)
        }
    }

    /// Moves an active note to another folder. Moving counts as a content-level change: it updates `modifiedAt`
    /// and increments the revision. Moving into the folder the note already has changes nothing.
    func moveNote(id: UUID, expectedRevision: Int64, toFolderID folderID: UUID) async throws -> NoteSnapshot {
        try await write { context, now in
            guard let note = try Self.fetch(
                NoteRecord.self,
                entity: "Note",
                in: context,
                predicate: NSPredicate(format: "id == %@", id as NSUUID)
            ).first else {
                throw LibraryError.noteNotFound(id)
            }
            guard note.revision == expectedRevision else {
                throw LibraryError.revisionConflict(id)
            }
            guard let folder = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "id == %@", folderID as NSUUID)
            ).first else {
                throw LibraryError.folderNotFound(folderID)
            }

            if note.folder?.id != folderID {
                note.folder = folder
                note.modifiedAt = now
                note.revision += 1
            }
            return try Self.snapshot(of: note)
        }
    }

    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot {
        try await write { context, now in
            guard let folder = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "id == %@", folderID as NSUUID)
            ).first else {
                throw LibraryError.folderNotFound(folderID)
            }

            let note = Self.insert(NoteRecord.self, entity: "Note", in: context)
            note.id = UUID()
            note.title = title
            note.bodyPlainText = bodyPlainText
            note.createdAt = now
            note.modifiedAt = now
            note.deletedAt = nil
            note.revision = 1
            note.isPinned = false
            note.folder = folder
            return try Self.snapshot(of: note)
        }
    }

    /// Saves edited text only if the stored revision still matches `expectedRevision`, so a stale editor can never
    /// overwrite newer data. Identical text is not a change: the revision and modification date stay the same.
    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot {
        try await write { context, now in
            guard let note = try Self.fetch(
                NoteRecord.self,
                entity: "Note",
                in: context,
                predicate: NSPredicate(format: "id == %@", id as NSUUID)
            ).first else {
                throw LibraryError.noteNotFound(id)
            }
            guard note.revision == expectedRevision else {
                throw LibraryError.revisionConflict(id)
            }
            // Plain text would drop the note's formatting, so a rich note is never saved through this path.
            guard note.contentFormatVersion == 0 else {
                throw LibraryError.richContentRequiresRichUpdate(id)
            }

            let titleChanged = !Self.sameScalars(note.title, title)
            let bodyChanged = !Self.sameScalars(note.bodyPlainText, bodyPlainText)
            if titleChanged || bodyChanged {
                note.title = title
                note.bodyPlainText = bodyPlainText
                note.modifiedAt = now
                note.revision += 1
            }
            return try Self.snapshot(of: note)
        }
    }

    /// The note's body as stored. A rich body is decoded and validated here; if it cannot be read, the result carries the
    /// saved plain text as a fallback and the stored data is not changed.
    func body(of id: UUID) async throws -> NoteBody {
        try await read { context in
            Self.readBody(of: try Self.fetchNote(id: id, in: context))
        }
    }

    /// Saves formatted text and its checklist in one transaction, with the same revision check as `updateNote`.
    /// Content is validated before anything is written. A note whose stored formatting cannot be read is refused,
    /// so a damaged original is never replaced by a newer save.
    func updateRichNote(id: UUID, expectedRevision: Int64, title: String, content: RichNoteContent) async throws -> NoteSnapshot {
        try RichTextCodec.validate(content)
        let checklistData = try content.checklist.map(RichTextCodec.encodeChecklist)
        return try await write { context, now in
            let note = try Self.fetchNote(id: id, in: context)
            guard note.revision == expectedRevision else {
                throw LibraryError.revisionConflict(id)
            }
            if note.contentFormatVersion != 0 {
                guard case .rich = Self.readBody(of: note) else {
                    throw LibraryError.richContentUnreadable(id)
                }
            }

            let changed = !Self.sameScalars(note.title, title)
                || !Self.sameScalars(note.bodyPlainText, content.plainText)
                || note.contentFormatVersion != Int32(RichNoteContent.formatVersion)
                || note.richTextData != content.rtf
                || note.checklistData != checklistData
            if changed {
                note.title = title
                note.bodyPlainText = content.plainText
                note.contentFormatVersion = Int32(RichNoteContent.formatVersion)
                note.richTextData = content.rtf
                note.checklistData = checklistData
                note.modifiedAt = now
                note.revision += 1
            }
            return try Self.snapshot(of: note)
        }
    }

    /// Creates a new plain-text note in the same folder from an unreadable note's saved text. The original is not changed.
    /// Only unreadable notes can be copied this way; a note that opens normally is edited in place instead.
    func makeRecoveryCopy(of id: UUID) async throws -> NoteSnapshot {
        try await write { context, now in
            let original = try Self.fetchNote(id: id, in: context)
            guard case .unreadable(let fallbackText, _) = Self.readBody(of: original) else {
                throw LibraryError.recoveryCopyNotNeeded(id)
            }
            guard let folder = original.folder else {
                throw LibraryError.libraryInconsistent("A note is missing its folder.")
            }

            let copy = Self.insert(NoteRecord.self, entity: "Note", in: context)
            copy.id = UUID()
            let originalTitle = original.title.isEmpty ? "Untitled Note" : original.title
            copy.title = "\(originalTitle) (Recovered)"
            copy.bodyPlainText = fallbackText
            copy.createdAt = now
            copy.modifiedAt = now
            copy.deletedAt = nil
            copy.revision = 1
            copy.isPinned = false
            copy.contentFormatVersion = 0
            copy.richTextData = nil
            copy.checklistData = nil
            copy.folder = folder
            return try Self.snapshot(of: copy)
        }
    }

    /// Active (not trashed) notes. Pass nil to include every folder. Newest modification first (see `NoteSnapshot.newestFirst`).
    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot] {
        try await read { context in
            var predicates = [NSPredicate(format: "deletedAt == nil")]
            if let folderID {
                predicates.append(NSPredicate(format: "folder.id == %@", folderID as NSUUID))
            }
            return try Self.fetch(
                NoteRecord.self,
                entity: "Note",
                in: context,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            )
            .map { try Self.snapshot(of: $0) }
            .sorted(by: NoteSnapshot.newestFirst)
        }
    }


    /// Soft delete: sets `deletedAt` and bumps the revision. Content, folder, and `modifiedAt` are not changed.
    /// Nothing is removed from the store.
    func trashNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot {
        try await write { context, now in
            let note = try Self.fetchNote(id: id, in: context)
            guard note.revision == expectedRevision else { throw LibraryError.revisionConflict(id) }
            guard note.deletedAt == nil else { throw LibraryError.noteAlreadyDeleted(id) }
            note.deletedAt = now
            note.revision += 1
            return try Self.snapshot(of: note)
        }
    }

    /// Clears `deletedAt`. The note returns to the folder it had when it was deleted.
    func restoreNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot {
        try await write { context, now in
            let note = try Self.fetchNote(id: id, in: context)
            guard note.revision == expectedRevision else { throw LibraryError.revisionConflict(id) }
            guard note.deletedAt != nil else { throw LibraryError.noteNotDeleted(id) }
            note.deletedAt = nil
            note.revision += 1
            return try Self.snapshot(of: note)
        }
    }

    /// Moves every note in the folder (active and trashed) to the default Notes folder, then removes the folder. Moved
    /// notes count as changed: their revision increases and, for active notes, `modifiedAt` is updated.
    func deleteFolder(id: UUID) async throws {
        try await write { context, now in
            guard let folder = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "id == %@", id as NSUUID)
            ).first else {
                throw LibraryError.folderNotFound(id)
            }
            guard !folder.isDefault else { throw LibraryError.defaultFolderIsFixed }
            guard let defaultFolder = try Self.fetch(
                FolderRecord.self,
                entity: "Folder",
                in: context,
                predicate: NSPredicate(format: "isDefault == YES")
            ).first else {
                throw LibraryError.libraryInconsistent("The default Notes folder is missing.")
            }

            let notes = try Self.fetch(
                NoteRecord.self,
                entity: "Note",
                in: context,
                predicate: NSPredicate(format: "folder.id == %@", id as NSUUID)
            )
            for note in notes {
                note.folder = defaultFolder
                note.revision += 1
                if note.deletedAt == nil {
                    note.modifiedAt = now
                }
            }
            context.delete(folder)
        }
    }

    /// Removes a note that is in Recently Deleted. Active notes are refused, so a live note can never be lost this way.
    func permanentlyDeleteNote(id: UUID, expectedRevision: Int64) async throws {
        try await write { context, _ in
            let note = try Self.fetchNote(id: id, in: context)
            guard note.revision == expectedRevision else { throw LibraryError.revisionConflict(id) }
            guard note.deletedAt != nil else { throw LibraryError.noteNotDeleted(id) }
            context.delete(note)
        }
    }

    /// Pins or unpins a note. Only the pin flag and the revision change; content and `modifiedAt` do not.
    func setNotePinned(id: UUID, expectedRevision: Int64, isPinned: Bool) async throws -> NoteSnapshot {
        try await write { context, _ in
            let note = try Self.fetchNote(id: id, in: context)
            guard note.revision == expectedRevision else { throw LibraryError.revisionConflict(id) }
            if note.isPinned != isPinned {
                note.isPinned = isPinned
                note.revision += 1
            }
            return try Self.snapshot(of: note)
        }
    }

    /// Notes in Recently Deleted, most recently deleted first.
    func deletedNotes() async throws -> [NoteSnapshot] {
        try await read { context in
            try Self.fetch(
                NoteRecord.self,
                entity: "Note",
                in: context,
                predicate: NSPredicate(format: "deletedAt != nil")
            )
            .map { try Self.snapshot(of: $0) }
            .sorted(by: NoteSnapshot.mostRecentlyDeletedFirst)
        }
    }

    private static func fetchNote(id: UUID, in context: NSManagedObjectContext) throws -> NoteRecord {
        guard let note = try fetch(
            NoteRecord.self,
            entity: "Note",
            in: context,
            predicate: NSPredicate(format: "id == %@", id as NSUUID)
        ).first else {
            throw LibraryError.noteNotFound(id)
        }
        return note
    }

    /// Literal substring match over active notes. `CONTAINS` takes the query as a bound value, so wildcards and
    /// regular-expression characters in user input have no special meaning. Results use the same order as listings.
    func searchActiveNotes(matching query: String) async throws -> [NoteSnapshot] {
        try await read { context in
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "deletedAt == nil"),
                NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "title CONTAINS[cd] %@", query),
                    NSPredicate(format: "bodyPlainText CONTAINS[cd] %@", query),
                ]),
            ])
            return try Self.fetch(NoteRecord.self, entity: "Note", in: context, predicate: predicate)
                .map { try Self.snapshot(of: $0) }
                .sorted(by: NoteSnapshot.newestFirst)
        }
    }

    // MARK: - Transaction helpers

    /// Runs one mutation and saves it. Any failure rolls the context back so no partial state stays in memory.
    private func write<T>(_ body: @escaping @Sendable (NSManagedObjectContext, Date) throws -> T) async throws -> T {
        let context = self.context
        let timestamp = now()
        return try await context.perform {
            do {
                let result = try body(context, timestamp)
                if context.hasChanges {
                    try context.save()
                }
                return result
            } catch let error as LibraryError {
                context.rollback()
                throw error
            } catch {
                context.rollback()
                throw LibraryError.saveFailed(error.localizedDescription)
            }
        }
    }

    private func read<T>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = self.context
        return try await context.perform {
            try body(context)
        }
    }

    private static func fetch<T: NSManagedObject>(
        _ type: T.Type,
        entity: String,
        in context: NSManagedObjectContext,
        predicate: NSPredicate? = nil,
        sortBy: [NSSortDescriptor] = []
    ) throws -> [T] {
        let request = NSFetchRequest<T>(entityName: entity)
        request.predicate = predicate
        request.sortDescriptors = sortBy
        return try context.fetch(request)
    }

    private static func insert<T: NSManagedObject>(
        _ type: T.Type,
        entity: String,
        in context: NSManagedObjectContext
    ) -> T {
        guard let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context) as? T else {
            preconditionFailure("Model entity \(entity) does not match \(T.self).")
        }
        return object
    }

    /// Compares Unicode scalars, not canonically equivalent strings, so a save never hides a change in encoding.
    private static func sameScalars(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    /// Reads a note's body without changing anything. A rich body that fails validation becomes `.unreadable`.
    private static func readBody(of note: NoteRecord) -> NoteBody {
        switch note.contentFormatVersion {
        case 0:
            return .plain(note.bodyPlainText)
        case Int32(RichNoteContent.formatVersion):
            guard let rtf = note.richTextData else {
                return .unreadable(fallbackText: note.bodyPlainText, reason: "The formatting data is missing.")
            }
            do {
                return .rich(try RichTextCodec.content(rtf: rtf, checklistData: note.checklistData))
            } catch {
                return .unreadable(fallbackText: note.bodyPlainText, reason: (error as? RichContentError).map { $0.localizedDescription } ?? "The formatting could not be read.")
            }
        default:
            let format = Int(note.contentFormatVersion)
            return .unreadable(
                fallbackText: note.bodyPlainText,
                reason: RichContentError.unsupportedContentFormat(format).localizedDescription
            )
        }
    }

    private static func snapshot(of record: NoteRecord) throws -> NoteSnapshot {
        guard let folderID = record.folder?.id else {
            throw LibraryError.libraryInconsistent("A note is missing its folder.")
        }
        return NoteSnapshot(
            id: record.id,
            folderID: folderID,
            title: record.title,
            bodyPlainText: record.bodyPlainText,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt,
            deletedAt: record.deletedAt,
            revision: record.revision,
            isPinned: record.isPinned,
            hasRichContent: record.contentFormatVersion != 0
        )
    }
}

// MARK: - Record-to-snapshot mapping

extension LibraryMetadataSnapshot {
    init(record: LibraryMetadataRecord) {
        self.init(libraryID: record.libraryID, createdAt: record.createdAt, formatVersion: Int(record.formatVersion))
    }
}

extension FolderSnapshot {
    init(record: FolderRecord) {
        self.init(
            id: record.id,
            name: record.name,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt,
            isDefault: record.isDefault
        )
    }
}
