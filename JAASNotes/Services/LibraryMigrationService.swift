import CoreData
import Foundation

/// Upgrades a library written by an earlier version of the model. The original is backed up first. The upgrade runs on a copy,
/// the copy's contents must match the original exactly, and only then is it installed with the same recoverable swap
/// that restores use. The original is never modified in place.
enum LibraryMigrationService {
    /// Test-only: stop after the copy is upgraded and checked, before anything in the library changes.
    enum Fault: Sendable {
        case afterUpgrade
    }

    /// Earlier model versions this app can upgrade from, newest first. Each is a compiled model in the bundle.
    static let priorModelNames = ["JAASNotes 3", "JAASNotes 2", "JAASNotes"]

    /// Upgrades the library at `location` when it was written by an earlier version. Returns true when an upgrade happened.
    /// A store that matches neither the current model nor a prior version is refused and left unchanged.
    @discardableResult
    static func migrateIfNeeded(_ location: LibraryLocation, takeBackup: Bool = true, fault: Fault? = nil) async throws -> Bool {
        let storeURL = location.storeURL
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }

        let current = try CoreDataStack.managedObjectModel()
        if try CoreDataStack.isCompatible(storeURL, with: current) {
            return false
        }
        var matched: NSManagedObjectModel?
        for name in priorModelNames {
            let candidate = try CoreDataStack.model(named: name)
            if try CoreDataStack.isCompatible(storeURL, with: candidate) {
                matched = candidate
                break
            }
        }
        guard let legacy = matched else {
            throw LibraryError.storeLoadFailed(
                "This library was written by a different version of JAASNotes, or it is not a JAASNotes library. It was not changed."
            )
        }

        if takeBackup {
            _ = try await LibraryBackupService.createSnapshot(
                of: location,
                kind: .preMigration,
                now: Date(),
                lastChangeAt: nil,
                legacyModel: legacy
            )
        }

        let fileManager = FileManager.default
        let folder = LibraryBackupService.stagingDirectory(in: location)
            .appending(path: "migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            // A private copy of the original, used as the migration source and for the comparison.
            let sourceFolder = folder.appending(path: "source", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try LibraryBackupService.copyStoreFiles(from: location.libraryDirectoryURL, to: sourceFolder)
            let sourceStore = sourceFolder.appending(path: "Store.sqlite", directoryHint: .notDirectory)
            let before = try contents(of: sourceStore, model: legacy)

            // Upgrade into the candidate library, then stamp it with the new format version.
            let candidateLibrary = folder.appending(path: "Library", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: candidateLibrary, withIntermediateDirectories: true)
            let candidateStore = candidateLibrary.appending(path: "Store.sqlite", directoryHint: .notDirectory)
            try upgrade(from: sourceStore, sourceModel: legacy, to: candidateStore, destinationModel: current)
            // The candidate replaces the whole library folder on install, so the attachment payloads must come with it.
            let attachments = AttachmentService.attachmentsDirectory(in: location)
            if fileManager.fileExists(atPath: attachments.path) {
                try fileManager.copyItem(at: attachments, to: candidateLibrary.appending(path: AttachmentService.attachmentsFolderName, directoryHint: .isDirectory))
            }
            try await stampFormatVersion(LibraryRepository.currentFormatVersion, in: LibraryLocation(rootURL: folder))

            // The upgrade must not change any note or folder.
            let after = try contents(of: candidateStore, model: current)
            guard before == after else {
                throw LibraryBackupError.validationFailed("The upgraded copy does not match the original, so it was not used.")
            }

            if fault == .afterUpgrade {
                throw LibraryBackupError.simulatedInterruption
            }
            _ = try await LibraryBackupService.validate(LibraryLocation(rootURL: folder))
            try await LibraryRestoreService.install(stagingFolder: folder, into: location)
        } catch LibraryBackupError.simulatedInterruption {
            try? fileManager.removeItem(at: folder)
            throw LibraryBackupError.simulatedInterruption
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return true
    }

    // MARK: - Upgrading

    private static func upgrade(
        from source: URL,
        sourceModel: NSManagedObjectModel,
        to destination: URL,
        destinationModel: NSManagedObjectModel
    ) throws {
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: sourceModel, destinationModel: destinationModel)
        let manager = NSMigrationManager(sourceModel: sourceModel, destinationModel: destinationModel)
        try manager.migrateStore(
            from: source,
            sourceType: NSSQLiteStoreType,
            options: nil,
            with: mapping,
            toDestinationURL: destination,
            destinationType: NSSQLiteStoreType,
            destinationOptions: nil
        )
    }

    /// Sets the library's format version in its metadata record. Opening the copy with the current model is safe
    /// because the upgrade has already brought its model hashes up to date.
    private static func stampFormatVersion(_ version: Int, in location: LibraryLocation) async throws {
        let container = try await CoreDataStack.openContainer(at: location)
        let context = container.newBackgroundContext()
        try context.performAndWait {
            let records = try context.fetch(NSFetchRequest<LibraryMetadataRecord>(entityName: "LibraryMetadata"))
            guard records.count == 1 else {
                throw LibraryBackupError.validationFailed("The upgraded copy has no single metadata record.")
            }
            records[0].formatVersion = Int32(version)
            try context.save()
        }
        try CoreDataStack.close(container)
    }

    /// Library identity and counts of a store read with the given model, for validating a version-1 snapshot.
    static func describe(_ storeURL: URL, model: NSManagedObjectModel) throws -> (libraryID: UUID, formatVersion: Int, counts: BackupCounts) {
        let contents = try contents(of: storeURL, model: model)
        let metadata = try metadata(of: storeURL, model: model)
        let folders = contents.folders
        guard folders.filter(\.isDefault).count == 1 else {
            throw LibraryBackupError.validationFailed("The library does not have exactly one default folder.")
        }
        let active = contents.notes.filter { $0.deletedAt == nil }.count
        return (
            metadata.libraryID,
            metadata.formatVersion,
            BackupCounts(folders: folders.count, activeNotes: active, deletedNotes: contents.notes.count - active)
        )
    }

    private static func metadata(of storeURL: URL, model: NSManagedObjectModel) throws -> (libraryID: UUID, formatVersion: Int) {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [NSReadOnlyPersistentStoreOption: true]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        defer {
            try? coordinator.remove(store)
        }
        return try context.performAndWait {
            let records = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "LibraryMetadata"))
            guard records.count == 1, let libraryID = records[0].value(forKey: "libraryID") as? UUID else {
                throw LibraryBackupError.validationFailed("The library has no single metadata record.")
            }
            return (libraryID, Int(records[0].value(forKey: "formatVersion") as? Int32 ?? 1))
        }
    }

    // MARK: - Comparing contents

    struct NoteRow: Equatable {
        let id: UUID
        let folderID: UUID?
        let title: String
        let body: String
        let revision: Int64
        let createdAt: Date
        let modifiedAt: Date
        let deletedAt: Date?
        let isPinned: Bool
    }

    struct FolderRow: Equatable {
        let id: UUID
        let name: String
        let normalizedName: String
        let createdAt: Date
        let modifiedAt: Date
        let isDefault: Bool
    }

    /// Every note and folder, read with the given model, sorted by identifier. Used to prove an upgrade changed nothing.
    struct Contents: Equatable {
        let folders: [FolderRow]
        let notes: [NoteRow]
    }

    /// Reads a store read-only with the given model. The file is only read, never written, because it is a private copy.
    static func contents(of storeURL: URL, model: NSManagedObjectModel) throws -> Contents {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [NSReadOnlyPersistentStoreOption: true]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        defer {
            try? coordinator.remove(store)
        }

        return try context.performAndWait {
            let folderObjects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Folder"))
            let folders = folderObjects.map { object in
                FolderRow(
                    id: object.value(forKey: "id") as? UUID ?? UUID(),
                    name: object.value(forKey: "name") as? String ?? "",
                    normalizedName: object.value(forKey: "normalizedName") as? String ?? "",
                    createdAt: object.value(forKey: "createdAt") as? Date ?? .distantPast,
                    modifiedAt: object.value(forKey: "modifiedAt") as? Date ?? .distantPast,
                    isDefault: object.value(forKey: "isDefault") as? Bool ?? false
                )
            }
            let noteObjects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note"))
            let notes = noteObjects.map { object in
                let folder = object.value(forKey: "folder") as? NSManagedObject
                return NoteRow(
                    id: object.value(forKey: "id") as? UUID ?? UUID(),
                    folderID: folder?.value(forKey: "id") as? UUID,
                    title: object.value(forKey: "title") as? String ?? "",
                    body: object.value(forKey: "bodyPlainText") as? String ?? "",
                    revision: object.value(forKey: "revision") as? Int64 ?? 0,
                    createdAt: object.value(forKey: "createdAt") as? Date ?? .distantPast,
                    modifiedAt: object.value(forKey: "modifiedAt") as? Date ?? .distantPast,
                    deletedAt: object.value(forKey: "deletedAt") as? Date,
                    isPinned: object.entity.attributesByName["isPinned"] != nil
                        ? (object.value(forKey: "isPinned") as? Bool ?? false)
                        : false
                )
            }
            return Contents(
                folders: folders.sorted { $0.id.uuidString < $1.id.uuidString },
                notes: notes.sorted { $0.id.uuidString < $1.id.uuidString }
            )
        }
    }
}
