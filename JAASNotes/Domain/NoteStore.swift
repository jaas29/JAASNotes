import Foundation

/// The durable operations the app needs. `LibraryRepository` implements them. Tests wrap it to inject failures.
protocol NoteStore: Sendable {
    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot
    func folders() async throws -> [FolderSnapshot]
    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot]
    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot
    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot
    /// Active notes whose title or body contains `query` literally, ignoring case and diacritics.
    func searchActiveNotes(matching query: String) async throws -> [NoteSnapshot]
    /// Moves an active note to Recently Deleted. Content, folder, and `modifiedAt` are kept.
    func trashNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot
    /// Returns a trashed note to active notes in the folder it was deleted from.
    func restoreNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot
    func deletedNotes() async throws -> [NoteSnapshot]
    func createFolder(named name: String) async throws -> FolderSnapshot
    func renameFolder(id: UUID, to name: String) async throws -> FolderSnapshot
    func moveNote(id: UUID, expectedRevision: Int64, toFolderID folderID: UUID) async throws -> NoteSnapshot
}
