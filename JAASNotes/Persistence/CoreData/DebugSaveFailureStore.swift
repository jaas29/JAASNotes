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
}
#endif
