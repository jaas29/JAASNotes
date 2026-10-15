import CoreData
import Foundation

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

    /// Removes the store from its coordinator so SQLite releases its file handles before a copy or reopen.
    static func close(_ container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    private static func managedObjectModel() throws -> NSManagedObjectModel {
        let bundle = Bundle(for: BundleToken.self)
        guard let modelURL = bundle.url(forResource: LibraryLocation.folderName, withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL)
        else {
            throw LibraryError.storeLoadFailed("The bundled data model is missing or unreadable.")
        }
        return model
    }
}
