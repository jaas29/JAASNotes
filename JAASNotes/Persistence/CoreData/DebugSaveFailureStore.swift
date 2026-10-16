import Foundation

#if DEBUG
/// Debug-only wrapper that rejects every write. Enabled with `JAASNOTES_TEST_FAIL_SAVES` so UI tests can exercise
/// the save-failure path, the status line, and the quit dialog. Compiled out of release builds.
actor DebugSaveFailureStore: NoteStore {
    private let base: NoteStore

    init(base: NoteStore) {
        self.base = base
    }

    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot {
        try await base.initializeLibraryIfNeeded()
    }

    func folders() async throws -> [FolderSnapshot] {
        try await base.folders()
    }

    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot] {
        try await base.activeNotes(inFolder: folderID)
    }

    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot {
        try await base.createNote(inFolder: folderID, title: title, bodyPlainText: bodyPlainText)
    }

    func searchActiveNotes(matching query: String) async throws -> [NoteSnapshot] {
        try await base.searchActiveNotes(matching: query)
    }

    func trashNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func restoreNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func deletedNotes() async throws -> [NoteSnapshot] {
        try await base.deletedNotes()
    }

    func setNotePinned(id: UUID, expectedRevision: Int64, isPinned: Bool) async throws -> NoteSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func deleteFolder(id: UUID) async throws {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func permanentlyDeleteNote(id: UUID, expectedRevision: Int64) async throws {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func createFolder(named name: String) async throws -> FolderSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func renameFolder(id: UUID, to name: String) async throws -> FolderSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }

    func moveNote(id: UUID, expectedRevision: Int64, toFolderID folderID: UUID) async throws -> NoteSnapshot {
        throw LibraryError.saveFailed("Writes are disabled for this test run.")
    }
}
#endif
