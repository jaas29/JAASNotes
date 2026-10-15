import Foundation

/// Immutable values handed across the repository boundary. Managed objects never leave the Core Data queue.
struct LibraryMetadataSnapshot: Equatable, Sendable {
    let libraryID: UUID
    let createdAt: Date
    let formatVersion: Int
}

struct FolderSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let isDefault: Bool
}

struct NoteSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    let folderID: UUID
    let title: String
    let bodyPlainText: String
    let createdAt: Date
    let modifiedAt: Date
    let deletedAt: Date?
    let revision: Int64
}

/// Typed failures. Messages must never include note text, titles, or full user paths.
enum LibraryError: Error, Equatable, Sendable {
    case emptyFolderName
    case reservedFolderName
    case duplicateFolderName
    case folderNotFound(UUID)
    case libraryInconsistent(String)
    case storeLoadFailed(String)
    case saveFailed(String)
}
