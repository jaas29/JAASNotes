import Foundation

/// The durable operations the app needs. `LibraryRepository` implements them. Tests wrap it to inject failures.
protocol NoteStore: Sendable {
    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot
    func folders() async throws -> [FolderSnapshot]
    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot]
    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot
    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot
}
