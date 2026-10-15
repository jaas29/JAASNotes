import CoreData
import Foundation
import Observation

/// App-level state for the open library: loaded snapshots, sidebar and note selection, and in-memory drafts.
/// Durable data lives in `LibraryRepository`. Drafts are kept in memory only until autosave (01-04) persists them.
@MainActor
@Observable
final class LibraryModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum SidebarSelection: Hashable {
        case allNotes
        case folder(UUID)
    }

    struct Draft: Equatable {
        var title: String
        var bodyPlainText: String
    }

    private(set) var phase: Phase = .loading
    private(set) var folders: [FolderSnapshot] = []
    private(set) var notes: [NoteSnapshot] = []
    private(set) var drafts: [UUID: Draft] = [:]
    private(set) var operationError: String?

    var sidebarSelection: SidebarSelection? = .allNotes
    var selectedNoteID: UUID?

    /// Set when a new note's title should take keyboard focus. The editor clears it after focusing.
    var titleFocusRequest: UUID?

    private var repository: LibraryRepository?
    private var hasStartedLoading = false

    var visibleNotes: [NoteSnapshot] {
        switch sidebarSelection {
        case .folder(let folderID):
            notes.filter { $0.folderID == folderID }
        case .allNotes, nil:
            notes
        }
    }

    var selectedNote: NoteSnapshot? {
        visibleNotes.first { $0.id == selectedNoteID }
    }

    func draft(for note: NoteSnapshot) -> Draft {
        drafts[note.id] ?? Draft(title: note.title, bodyPlainText: note.bodyPlainText)
    }

    func displayTitle(for note: NoteSnapshot) -> String {
        draft(for: note).title
    }

    func updateDraft(for noteID: UUID, title: String? = nil, body: String? = nil) {
        guard let note = notes.first(where: { $0.id == noteID }) else { return }
        var draft = draft(for: note)
        if let title {
            draft.title = title
        }
        if let body {
            draft.bodyPlainText = body
        }
        drafts[noteID] = draft
    }

    func clearOperationError() {
        operationError = nil
    }

    /// Opens the library once per model. Repeated `.task` runs (for example, when the window reappears) do nothing.
    func loadIfNeeded() async {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        do {
            await load(at: try Self.resolveLocation())
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func load(at location: LibraryLocation) async {
        do {
            let container = try await CoreDataStack.openContainer(at: location)
            let repository = LibraryRepository(container: container)
            _ = try await repository.initializeLibraryIfNeeded()
            self.repository = repository
            try await refresh()
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// New notes go to the selected folder, or to the default Notes folder when All Notes is selected.
    func createNote() async {
        guard phase == .ready, let repository, let defaultFolder = folders.first(where: \.isDefault) else { return }
        let folderID: UUID
        if case .folder(let selectedFolderID) = sidebarSelection {
            folderID = selectedFolderID
        } else {
            folderID = defaultFolder.id
        }

        do {
            let note = try await repository.createNote(inFolder: folderID, title: "", bodyPlainText: "")
            try await refresh()
            selectedNoteID = note.id
            titleFocusRequest = note.id
        } catch {
            operationError = Self.message(for: error)
        }
    }

    private func refresh() async throws {
        guard let repository else { return }
        folders = try await repository.folders()
        notes = try await repository.activeNotes()
    }

    /// Debug builds can open a named library inside the app's own sandbox temporary folder. A sandboxed app
    /// cannot write to the test runner's temporary folder, so the test passes a name rather than a path.
    /// The override is compiled out of release builds.
    private static func resolveLocation() throws -> LibraryLocation {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["JAASNOTES_TEST_LIBRARY_NAME"] {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "JAASNotesTest-\(name)", directoryHint: .isDirectory)
            return LibraryLocation(rootURL: root)
        }
        #endif
        return try LibraryLocation.applicationDefault()
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The library operation failed."
    }
}
