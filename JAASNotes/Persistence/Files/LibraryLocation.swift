import Foundation

/// Stable on-disk layout for one library. The root is injected so tests use temporary directories.
struct LibraryLocation: Equatable, Sendable {
    static let folderName = "JAASNotes"

    /// `Application Support/JAASNotes` in the normal app; a temporary directory in tests.
    let rootURL: URL

    var libraryDirectoryURL: URL {
        rootURL.appending(path: "Library", directoryHint: .isDirectory)
    }

    /// Core Data owns this file and its `-wal` and `-shm` companions. Never edit them directly.
    var storeURL: URL {
        libraryDirectoryURL.appending(path: "Store.sqlite", directoryHint: .notDirectory)
    }

    static func applicationDefault(fileManager: FileManager = .default) throws -> LibraryLocation {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LibraryLocation(rootURL: support.appending(path: folderName, directoryHint: .isDirectory))
    }
}
