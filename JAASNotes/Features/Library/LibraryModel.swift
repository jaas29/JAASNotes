import Foundation
import Observation

/// App-level state for the open library: snapshots, selection, drafts, and the autosave state machine.
///
/// Every edit bumps a per-note draft revision. A note is dirty while its draft revision differs from the last
/// revision the store acknowledged. Saves are serialized, and a save reports success only after the store confirms it.
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

    enum SaveStatus: Equatable {
        case saved
        case unsaved
        case saving
        case failed(String)
    }

    typealias Clock = @Sendable () -> Date
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Quiet time after the last keystroke before autosave runs.
    static let debounceInterval: Duration = .milliseconds(500)
    /// Longest time unsaved text may wait while typing continues.
    static let maximumUnsavedInterval: TimeInterval = 2

    private(set) var phase: Phase = .loading
    private(set) var folders: [FolderSnapshot] = []
    private(set) var notes: [NoteSnapshot] = []
    private(set) var drafts: [UUID: Draft] = [:]
    private(set) var operationError: String?
    private(set) var saveFailures: [UUID: String] = [:]

    var sidebarSelection: SidebarSelection? = .allNotes
    var selectedNoteID: UUID?

    /// Set when a new note's title should take keyboard focus. The editor clears it after focusing.
    var titleFocusRequest: UUID?

    /// The first failure message, if any save is failing.
    var saveFailure: String? {
        saveFailures.values.first
    }

    private var store: NoteStore?
    private var hasStartedLoading = false
    private let clock: Clock
    private let sleep: Sleeper

    private var draftRevisions: [UUID: Int] = [:]
    private var savedDraftRevisions: [UUID: Int] = [:]
    private var savingNoteIDs: Set<UUID> = []
    private var firstUnsavedEdit: [UUID: Date] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var flushTask: Task<Bool, Never>?

    init(
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.clock = clock
        self.sleep = sleep
    }

    // MARK: - Reading state

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

    var hasUnsavedChanges: Bool {
        draftRevisions.keys.contains { isDirty($0) }
    }

    func isDirty(_ noteID: UUID) -> Bool {
        (draftRevisions[noteID] ?? 0) != (savedDraftRevisions[noteID] ?? 0)
    }

    func saveStatus(for noteID: UUID) -> SaveStatus {
        if savingNoteIDs.contains(noteID) {
            return .saving
        }
        if let message = saveFailures[noteID] {
            return .failed(message)
        }
        return isDirty(noteID) ? .unsaved : .saved
    }

    func draft(for note: NoteSnapshot) -> Draft {
        drafts[note.id] ?? Draft(title: note.title, bodyPlainText: note.bodyPlainText)
    }

    func displayTitle(for note: NoteSnapshot) -> String {
        draft(for: note).title
    }

    // MARK: - Editing

    func updateDraft(for noteID: UUID, title: String? = nil, body: String? = nil) {
        guard let note = notes.first(where: { $0.id == noteID }) else { return }
        let current = draft(for: note)
        var updated = current
        if let title {
            updated.title = title
        }
        if let body {
            updated.bodyPlainText = body
        }
        // Views can report unchanged text (for example, when focus moves). That is not an edit, so it must not
        // make the note dirty or start a save.
        guard !Self.sameText(updated, current) else { return }
        drafts[noteID] = updated
        draftRevisions[noteID, default: 0] += 1

        let now = clock()
        if firstUnsavedEdit[noteID] == nil {
            firstUnsavedEdit[noteID] = now
        }
        scheduleAutosave(for: noteID, now: now)
    }

    private func scheduleAutosave(for noteID: UUID, now: Date) {
        debounceTasks[noteID]?.cancel()

        let waitingSince = firstUnsavedEdit[noteID] ?? now
        let delay: Duration = now.timeIntervalSince(waitingSince) >= Self.maximumUnsavedInterval
            ? .zero
            : Self.debounceInterval
        let sleep = self.sleep

        debounceTasks[noteID] = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                // Cancelled by a newer edit, which schedules its own save.
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushPendingDrafts()
        }
    }

    // MARK: - Saving

    /// Saves every dirty note. Returns true only when each dirty note has been acknowledged by the store.
    /// Overlapping calls queue behind the save in progress, so saves never run concurrently.
    @discardableResult
    func flushPendingDrafts() async -> Bool {
        while let inFlight = flushTask {
            _ = await inFlight.value
        }
        let task = Task { [weak self] () -> Bool in
            let saved = await self?.runFlushPass() ?? false
            // Clear the slot before anyone awaiting this task resumes, so the next caller starts a fresh pass.
            self?.flushTask = nil
            return saved
        }
        flushTask = task
        return await task.value
    }

    /// Retry after a failed save. Behaves exactly like a normal flush.
    @discardableResult
    func retrySave() async -> Bool {
        await flushPendingDrafts()
    }

    private func runFlushPass() async -> Bool {
        guard let store else { return !hasUnsavedChanges }

        while let note = notes.first(where: { isDirty($0.id) }) {
            // Capture exactly what is being saved. Edits made during the await stay dirty for the next pass.
            let noteID = note.id
            let text = draft(for: note)
            let revision = draftRevisions[noteID] ?? 0

            // The previous failure message stays until a save succeeds. Clearing it here would re-present the failure
            // alert on every retry, such as one triggered by the window losing focus.
            savingNoteIDs.insert(noteID)
            do {
                let saved = try await store.updateNote(
                    id: noteID,
                    expectedRevision: note.revision,
                    title: text.title,
                    bodyPlainText: text.bodyPlainText
                )
                savingNoteIDs.remove(noteID)
                saveFailures[noteID] = nil
                replaceNote(saved)
                savedDraftRevisions[noteID] = revision
                if !isDirty(noteID) {
                    firstUnsavedEdit[noteID] = nil
                }
            } catch {
                savingNoteIDs.remove(noteID)
                saveFailures[noteID] = Self.message(for: error)
                return false
            }
        }
        return true
    }

    private func replaceNote(_ saved: NoteSnapshot) {
        if let index = notes.firstIndex(where: { $0.id == saved.id }) {
            notes[index] = saved
        }
    }

    /// Drops unsaved text for every dirty note; each note returns to its stored text. Call only when no save is in
    /// progress, and only after the user has confirmed.
    func discardUnsavedChanges() {
        for noteID in draftRevisions.keys where isDirty(noteID) {
            drafts[noteID] = nil
            savedDraftRevisions[noteID] = draftRevisions[noteID]
            firstUnsavedEdit[noteID] = nil
            saveFailures[noteID] = nil
            debounceTasks[noteID]?.cancel()
        }
    }

    // MARK: - Recovery

    func unsavedDraftsForRecovery() -> [RecoveryDraft] {
        notes.compactMap { note in
            guard isDirty(note.id) else { return nil }
            let text = draft(for: note)
            return RecoveryDraft(
                noteID: note.id,
                folderID: note.folderID,
                title: text.title,
                bodyPlainText: text.bodyPlainText,
                savedRevision: note.revision
            )
        }
    }

    /// Writes unsaved text to a user-chosen file and verifies it. Failures are reported through `operationError`.
    @discardableResult
    func saveRecoveryCopy(to url: URL) -> Bool {
        let drafts = unsavedDraftsForRecovery()
        guard !drafts.isEmpty else {
            operationError = "There are no unsaved changes to copy."
            return false
        }
        do {
            try RecoveryCopy.write(drafts, to: url, exportedAt: clock())
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Selection and commands

    /// Changing notes first saves pending text. If the save fails, the selection stays where it is.
    func requestNoteSelection(_ noteID: UUID?) async {
        if hasUnsavedChanges {
            guard await flushPendingDrafts() else { return }
        }
        selectedNoteID = noteID
    }

    /// Changing folders first saves pending text. If the save fails, the selection stays where it is.
    func requestSidebarSelection(_ selection: SidebarSelection?) async {
        if hasUnsavedChanges {
            guard await flushPendingDrafts() else { return }
        }
        sidebarSelection = selection
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
            var store: NoteStore = LibraryRepository(container: container)
            #if DEBUG
            if ProcessInfo.processInfo.environment["JAASNOTES_TEST_FAIL_SAVES"] != nil {
                store = DebugSaveFailureStore(base: store)
            }
            #endif
            await load(store: store)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Opens an existing store. Tests pass a wrapper that injects failures.
    func load(store: NoteStore) async {
        do {
            _ = try await store.initializeLibraryIfNeeded()
            self.store = store
            try await refresh()
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// New notes go to the selected folder, or to the default Notes folder when All Notes is selected.
    /// Pending text is saved first, and creation is refused if that save fails.
    func createNote() async {
        guard phase == .ready, let store, let defaultFolder = folders.first(where: \.isDefault) else { return }
        guard await flushPendingDrafts() else { return }

        let folderID: UUID
        if case .folder(let selectedFolderID) = sidebarSelection {
            folderID = selectedFolderID
        } else {
            folderID = defaultFolder.id
        }

        do {
            let note = try await store.createNote(inFolder: folderID, title: "", bodyPlainText: "")
            try await refresh()
            selectedNoteID = note.id
            titleFocusRequest = note.id
        } catch {
            operationError = Self.message(for: error)
        }
    }

    private func refresh() async throws {
        guard let store else { return }
        folders = try await store.folders()
        notes = try await store.activeNotes(inFolder: nil)
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

    /// Compares Unicode scalars, so canonically equivalent but differently encoded text still counts as a change.
    private static func sameText(_ lhs: Draft, _ rhs: Draft) -> Bool {
        lhs.title.unicodeScalars.elementsEqual(rhs.title.unicodeScalars)
            && lhs.bodyPlainText.unicodeScalars.elementsEqual(rhs.bodyPlainText.unicodeScalars)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The library operation failed."
    }
}
