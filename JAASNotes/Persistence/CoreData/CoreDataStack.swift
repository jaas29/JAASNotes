import CoreData
import Foundation
import SQLite3

/// Opens and closes the Core Data SQLite store. Automatic migration is disabled: migrations are explicit steps
/// added in later stages, never silent changes to the only copy of a user's library.
enum CoreDataStack {
    private final class BundleToken {}

    static func openContainer(at location: LibraryLocation) async throws -> NSPersistentContainer {
        let model = try managedObjectModel()
        let container = NSPersistentContainer(name: LibraryLocation.folderName, managedObjectModel: model)

        try FileManager.default.createDirectory(
            at: location.libraryDirectoryURL,
            withIntermediateDirectories: true
        )
        try checkCompatibility(of: location.storeURL, with: model)

        let description = NSPersistentStoreDescription(url: location.storeURL)
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        container.persistentStoreDescriptions = [description]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: LibraryError.storeLoadFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        return container
    }

    /// Reads the existing store's metadata without opening it for writing. A store this model cannot read is refused,
    /// so a foreign file or a newer library is never given Core Data tables or treated as an empty library.
    static func checkCompatibility(of storeURL: URL, with model: NSManagedObjectModel) throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard try isCompatible(storeURL, with: model) else {
            throw LibraryError.storeLoadFailed(
                "The library was written by a different version of JAASNotes, or it is not a JAASNotes library. It was not changed."
            )
        }
    }

    /// True when the file is a Core Data SQLite store that `model` can read without migration. Never writes to the file.
    static func isCompatible(_ storeURL: URL, with model: NSManagedObjectModel) throws -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        // Core Data's own table must be there. Reading metadata through Core Data would write to a foreign file,
        // so this check uses a read-only SQLite connection first.
        guard hasCoreDataMetadataTable(storeURL) else { return false }
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: storeURL,
                options: nil
            )
        } catch {
            throw LibraryError.storeLoadFailed("The library file could not be read. It was not changed.")
        }
        // A file without Core Data's model hashes is not a Core Data store. Some Core Data versions treat empty
        // metadata as compatible, so the hash key is required as well.
        return metadata[NSStoreModelVersionHashesKey] != nil
            && model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    /// A model from the compiled bundle, such as version 1 (`JAASNotes`) or the current version (`JAASNotes 2`).
    static func model(named name: String) throws -> NSManagedObjectModel {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "mom", subdirectory: "\(LibraryLocation.folderName).momd"),
              let model = NSManagedObjectModel(contentsOf: url)
        else {
            throw LibraryError.storeLoadFailed("The bundled data model \(name) is missing or unreadable.")
        }
        return model
    }

    /// True when the file is a SQLite database with Core Data's `Z_METADATA` table. Opens read-only and never writes.
    private static func hasCoreDataMetadataTable(_ url: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Z_METADATA'"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Removes the store from its coordinator so SQLite releases its file handles before a copy or reopen.
    static func close(_ container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    static func managedObjectModel() throws -> NSManagedObjectModel {
        let bundle = Bundle(for: BundleToken.self)
        guard let modelURL = bundle.url(forResource: LibraryLocation.folderName, withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL)
        else {
            throw LibraryError.storeLoadFailed("The bundled data model is missing or unreadable.")
        }
        return model
    }
}
