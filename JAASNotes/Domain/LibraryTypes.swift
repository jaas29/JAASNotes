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
    case noteNotFound(UUID)
    case revisionConflict(UUID)
    case libraryInconsistent(String)
    case storeLoadFailed(String)
    case saveFailed(String)
}

extension LibraryError: LocalizedError {
    /// User-facing text. Associated storage details are deliberately omitted to keep paths and raw errors out of the UI.
    var errorDescription: String? {
        switch self {
        case .emptyFolderName:
            "Folder names cannot be empty."
        case .reservedFolderName:
            "That name is reserved for a built-in list."
        case .duplicateFolderName:
            "A folder with that name already exists."
        case .folderNotFound:
            "The folder no longer exists."
        case .noteNotFound:
            "The note no longer exists."
        case .revisionConflict:
            "This note was changed somewhere else, so your edits were not saved over it."
        case .libraryInconsistent(let detail):
            "The library data is inconsistent, so nothing was changed. \(detail)"
        case .storeLoadFailed:
            "The library database could not be opened."
        case .saveFailed:
            "Your changes could not be saved."
        }
    }
}
