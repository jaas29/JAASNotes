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

extension NoteSnapshot {
    /// Newest modification first. Equal dates fall back to the UUID string so the order never changes between reads.
    static func newestFirst(_ lhs: NoteSnapshot, _ rhs: NoteSnapshot) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Most recently deleted first. Trashed notes are ordered by when they were deleted, not when they were edited.
    static func mostRecentlyDeletedFirst(_ lhs: NoteSnapshot, _ rhs: NoteSnapshot) -> Bool {
        let lhsDate = lhs.deletedAt ?? .distantPast
        let rhsDate = rhs.deletedAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Typed failures. Messages must never include note text, titles, or full user paths.
enum LibraryError: Error, Equatable, Sendable {
    case emptyFolderName
    case reservedFolderName
    case duplicateFolderName
    case defaultFolderIsFixed
    case noteAlreadyDeleted(UUID)
    case noteNotDeleted(UUID)
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
        case .defaultFolderIsFixed:
            "The Notes folder cannot be renamed or deleted."
        case .noteAlreadyDeleted:
            "This note is already in Recently Deleted."
        case .noteNotDeleted:
            "This note is not in Recently Deleted."
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

/// In-memory matching that mirrors the store's literal search: no regular expressions, case and diacritics ignored.
enum NoteSearch {
    static func matches(title: String, body: String, query: String) -> Bool {
        contains(title, query) || contains(body, query)
    }

    static func contains(_ text: String, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
