import CoreData
import Foundation

/// The single writer for one library. Each mutation runs in one transaction on a private-queue context and
/// is saved to the persistent store before it returns. Callers receive value snapshots only.
actor LibraryRepository: NoteStore {
    static let defaultFolderName = "Notes"
    static let currentFormatVersion = 1

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

    /// Active (not trashed) notes. Pass nil to include every folder. Newest modification first.
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
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates),
                sortBy: [NSSortDescriptor(key: "modifiedAt", ascending: false)]
            )
            .map { try Self.snapshot(of: $0) }
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
            revision: record.revision
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
