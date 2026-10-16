import Foundation

/// The durable operations the app needs. `LibraryRepository` implements them. Tests wrap it to inject failures.
protocol NoteStore: AttachmentStore {
    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot
    func folders() async throws -> [FolderSnapshot]
    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot]
    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot
    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot
    /// The note's body as stored. Damaged formatting is reported with the saved text; nothing is changed.
    func body(of id: UUID) async throws -> NoteBody
    /// Saves formatted text and its checklist with the same revision rule as `updateNote`.
    func updateRichNote(id: UUID, expectedRevision: Int64, title: String, content: RichNoteContent) async throws -> NoteSnapshot
    /// Creates a plain-text note from an unreadable note's saved text, in the same folder. The original is not changed.
    func makeRecoveryCopy(of id: UUID) async throws -> NoteSnapshot
    /// Active notes whose title or body contains `query` literally, ignoring case and diacritics.
    func searchActiveNotes(matching query: String) async throws -> [NoteSnapshot]
    /// Moves an active note to Recently Deleted. Content, folder, and `modifiedAt` are kept.
    func trashNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot
    /// Returns a trashed note to active notes in the folder it was deleted from.
    func restoreNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot
    func deletedNotes() async throws -> [NoteSnapshot]
    /// Removes a user folder. Its active and trashed notes move to the default folder first, in the same transaction.
    func deleteFolder(id: UUID) async throws
    /// Removes a note that is already in Recently Deleted. Nothing else is removed.
    func permanentlyDeleteNote(id: UUID, expectedRevision: Int64) async throws
    /// Pinning is not a content edit: it bumps the revision but keeps `modifiedAt`.
    func setNotePinned(id: UUID, expectedRevision: Int64, isPinned: Bool) async throws -> NoteSnapshot
    func createFolder(named name: String) async throws -> FolderSnapshot
    func renameFolder(id: UUID, to name: String) async throws -> FolderSnapshot
    func moveNote(id: UUID, expectedRevision: Int64, toFolderID folderID: UUID) async throws -> NoteSnapshot
    /// Writes an archive import in one transaction: every folder, note, and attachment row, or none of them.
    func importArchive(_ plan: ArchiveImportPlan) async throws
}
