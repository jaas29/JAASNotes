import CoreData
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
        case recentlyDeleted
    }

    enum FolderSheetRequest: Equatable {
        case create
        case rename(UUID)
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

    /// Which notes a search covers. "This Folder" narrows results to the folder selected in the sidebar.
    enum SearchScope: Hashable {
        case allNotes
        case currentFolder
    }

    typealias Clock = @Sendable () -> Date
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Quiet time after the last keystroke before autosave runs.
    static let debounceInterval: Duration = .milliseconds(500)
    /// Longest time unsaved text may wait while typing continues.
    static let maximumUnsavedInterval: TimeInterval = 2
    /// Quiet time after the last search keystroke before the store is queried.
    static let searchDebounceInterval: Duration = .milliseconds(200)

    private static let sortOrderKey = "org.jaasnotes.noteSortOrder"

    private(set) var phase: Phase = .loading
    private(set) var folders: [FolderSnapshot] = []
    private(set) var notes: [NoteSnapshot] = []
    /// Trashed notes. They are read-only and kept out of `notes`, so no path can autosave them.
    private(set) var deletedNotes: [NoteSnapshot] = []
    private(set) var drafts: [UUID: Draft] = [:]
    private(set) var operationError: String?
    private(set) var saveFailures: [UUID: String] = [:]

    /// The note list order. Stored in preferences, not in the library. Changing it re-orders rows but never drafts.
    var sortOrder: NoteSortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: Self.sortOrderKey)
            applyListOrder()
        }
    }

    var sidebarSelection: SidebarSelection? = .allNotes
    var selectedNoteID: UUID?

    /// The search text as typed. Empty means no search.
    private(set) var searchText = ""
    var searchScope: SearchScope = .allNotes
    /// Stored notes that matched the latest completed query. Drafts are matched in memory on top of this.
    private(set) var searchMatchIDs: Set<UUID> = []
    /// The debounced search in progress, if any. Exposed so tests can wait for it.
    private(set) var pendingSearch: Task<Void, Never>?

    /// Set when a new note's title should take keyboard focus. The editor clears it after focusing.
    var titleFocusRequest: UUID?

    /// Set by menu commands. The shell presents the folder sheet and clears the request.
    var folderSheetRequest: FolderSheetRequest?
    /// Set by the Backups command. The shell presents the backups sheet and clears the request.
    var backupsSheetRequested = false
    /// Set by the Search Notes command. The note list moves keyboard focus to its search field and clears the request.
    var searchFocusRequested = false

    /// The first failure message, if any save is failing.
    var saveFailure: String? {
        saveFailures.values.first
    }

    private var store: NoteStore?
    /// The open Core Data container for the library. Nil in tests that open a store directly.
    private var container: NSPersistentContainer?
    private var location: LibraryLocation?
    private var hasStartedLoading = false

    /// True while a backup or restore closes and reopens the store. Operations that need the store wait for it.
    private(set) var isLibraryLocked = false
    private(set) var backups: [BackupSummary] = []
    private(set) var backupMessage: String?

    /// The store to use right now. Nil while the library is locked, so nothing writes to a closed store.
    private var activeStore: NoteStore? {
        isLibraryLocked ? nil : store
    }
    private let clock: Clock
    private let sleep: Sleeper
    private let searchSleep: Sleeper
    private let defaults: UserDefaults
    /// Bumped by every search edit or save. A search result is applied only if its generation is still current.
    private var searchGeneration = 0

    private var draftRevisions: [UUID: Int] = [:]
    private var savedDraftRevisions: [UUID: Int] = [:]
    private var savingNoteIDs: Set<UUID> = []
    private var firstUnsavedEdit: [UUID: Date] = [:]
    private var debounceTasks: [UUID: Task<Void, Never>] = [:]
    private var flushTask: Task<Bool, Never>?

    init(
        clock: @escaping Clock = { Date() },
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        searchSleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        defaults: UserDefaults = .standard
    ) {
        self.clock = clock
        self.sleep = sleep
        self.searchSleep = searchSleep
        self.defaults = defaults
        self.sortOrder = NoteSortOrder(rawValue: defaults.string(forKey: Self.sortOrderKey) ?? "") ?? .modified
    }

    // MARK: - Reading state

    var visibleNotes: [NoteSnapshot] {
        switch sidebarSelection {
        case .folder(let folderID):
            notes.filter { $0.folderID == folderID }
        case .recentlyDeleted:
            deletedNotes
        case .allNotes, nil:
            notes
        }
    }

    var isShowingRecentlyDeleted: Bool {
        sidebarSelection == .recentlyDeleted
    }

    /// Notes shown in the list: the sidebar selection, or the search results while a search is active.
    /// Search results include unsaved drafts, so a database match never hides text that has not been saved yet.
    var listedNotes: [NoteSnapshot] {
        guard isSearching else { return visibleNotes }
        if isShowingRecentlyDeleted {
            // Trash is searched only when Recently Deleted is selected. Its notes are read-only, so no drafts apply.
            return deletedNotes.filter { note in
                NoteSearch.matches(title: note.title, body: note.bodyPlainText, query: searchText)
            }
        }
        let scopeFolderID = searchScopeFolderID
        return notes.filter { note in
            if let scopeFolderID, note.folderID != scopeFolderID { return false }
            guard !searchMatchIDs.contains(note.id) else { return true }
            let text = draft(for: note)
            return NoteSearch.matches(title: text.title, body: text.bodyPlainText, query: searchText)
        }
    }

    var isSearching: Bool {
        !searchText.isEmpty
    }

    /// The folder "This Folder" limits results to, or nil for every folder.
    var searchScopeFolderID: UUID? {
        guard searchScope == .currentFolder, case .folder(let folderID) = sidebarSelection else { return nil }
        return folderID
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

    // MARK: - Search

    /// Updates the search text and schedules a debounced store query. Typing never waits for the store.
    func setSearchText(_ text: String) {
        searchText = text
        scheduleSearch()
    }

    /// Ends the search and restores the normal list. Pending drafts are unaffected.
    func clearSearch() {
        setSearchText("")
    }

    private func scheduleSearch() {
        searchGeneration += 1
        pendingSearch?.cancel()
        pendingSearch = nil
        guard isSearching else {
            searchMatchIDs = []
            return
        }
        let generation = searchGeneration
        let sleep = searchSleep
        pendingSearch = Task { [weak self] in
            do {
                try await sleep(Self.searchDebounceInterval)
            } catch {
                // Replaced by a newer search or edit, which schedules its own query.
                return
            }
            await self?.runSearch(generation: generation)
        }
    }

    /// Queries the store for the text that is current for `generation`. A result from an older generation is dropped,
    /// so a slow query can never replace the results of a newer one.
    private func runSearch(generation: Int) async {
        guard let store = activeStore, generation == searchGeneration else { return }
        let query = searchText
        do {
            let matches = try await store.searchActiveNotes(matching: query)
            guard generation == searchGeneration else { return }
            searchMatchIDs = Set(matches.map(\.id))
        } catch {
            guard generation == searchGeneration else { return }
            searchMatchIDs = []
            operationError = Self.message(for: error)
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
        guard let store = activeStore else { return !hasUnsavedChanges }

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
                if isSearching {
                    scheduleSearch()
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

    // MARK: - Backups and restores

    /// The most recent backup of any kind, for the "last backed up" status.
    var lastBackupDate: Date? {
        backups.first?.createdAt
    }

    func refreshBackups() {
        guard let location else {
            backups = []
            return
        }
        do {
            backups = try LibraryBackupService.list(in: location)
        } catch {
            backupMessage = Self.message(for: error)
        }
    }

    /// Takes a manual backup. Pending text is saved first, and the library is locked while the copy is made.
    @discardableResult
    func backUpNow() async -> Bool {
        await takeBackup(kind: .manual)
    }

    /// Takes an automatic backup at most once a day, and only when the library changed since the last one.
    /// Called when the app becomes active. Failures are shown in the backups sheet and never block the app.
    func performAutomaticBackupIfDue() async {
        guard phase == .ready, !isLibraryLocked, container != nil else { return }
        let now = clock()
        let lastAutomatic = backups.first { $0.kind == .automatic }?.createdAt
        if let lastAutomatic, now.timeIntervalSince(lastAutomatic) < 24 * 60 * 60 {
            return
        }
        if let lastAutomatic, let lastChange = latestChangeDate(), lastChange <= lastAutomatic {
            return
        }
        await takeBackup(kind: .automatic)
    }

    /// Restores a backup over the current library. The current library is first backed up, if it can be read.
    /// If that backup fails, the restore does not start. The previous library is kept in Recovery either way.
    @discardableResult
    func restoreBackup(_ backup: BackupSummary) async -> Bool {
        guard let location, !isLibraryLocked else { return false }
        if container != nil, phase == .ready {
            guard await takeBackup(kind: .preRestore) else { return false }
        }

        isLibraryLocked = true
        closeStore()
        do {
            try await LibraryRestoreService.restore(backup, into: location)
        } catch {
            isLibraryLocked = false
            backupMessage = Self.message(for: error)
            // Try to reopen whatever is on disk so the user can see it or try again.
            await reopenAfterOperation(location)
            return false
        }
        isLibraryLocked = false
        resetDraftState()
        await reopenAfterOperation(location)
        refreshBackups()
        return phase == .ready
    }

    /// Opens the library after a store-open failure again. The first step of the recovery screen.
    func retryOpening() async {
        guard let location else { return }
        phase = .loading
        hasStartedLoading = true
        await load(at: location)
    }

    /// Moves the current library folder into Recovery and opens a new, empty library. The old one is never deleted.
    func createNewLibraryPreservingExisting() async -> Bool {
        guard let location, !isLibraryLocked else { return false }
        isLibraryLocked = true
        closeStore()
        do {
            _ = try LibraryBackupService.moveLibraryAside(location)
        } catch {
            isLibraryLocked = false
            backupMessage = Self.message(for: error)
            return false
        }
        isLibraryLocked = false
        resetDraftState()
        phase = .loading
        await load(at: location)
        return phase == .ready
    }

    /// Copies a complete backup package to a folder the user chose, then checks the copy against its manifest.
    /// The package is an ordinary folder, so it can also be kept on another disk or in another backup system.
    @discardableResult
    func exportBackup(_ backup: BackupSummary, to folder: URL) -> Bool {
        let target = folder.appending(path: backup.url.lastPathComponent, directoryHint: .isDirectory)
        do {
            try FileManager.default.copyItem(at: backup.url, to: target)
            let manifest = try LibraryBackupService.readManifest(in: target)
            try LibraryBackupService.verifyChecksums(of: manifest, in: target)
            backupMessage = "Backup copied and checked: \(target.lastPathComponent)"
            return true
        } catch {
            backupMessage = Self.message(for: error)
            return false
        }
    }

    /// Writes sanitized diagnostics: versions, file sizes and dates, and backup counts. Never note text or paths.
    @discardableResult
    func saveDiagnosticInfo(to url: URL) -> Bool {
        guard let location else { return false }
        do {
            let report = try LibraryBackupService.diagnosticReport(
                of: location,
                failure: phaseFailureMessage,
                now: clock()
            )
            try report.write(to: url, options: .atomic)
            return true
        } catch {
            backupMessage = Self.message(for: error)
            return false
        }
    }

    var phaseFailureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Takes one snapshot of the open library: flush, close, copy, validate, publish, reopen.
    @discardableResult
    private func takeBackup(kind: BackupKind) async -> Bool {
        guard let location, container != nil, phase == .ready, !isLibraryLocked else { return false }
        guard await flushPendingDrafts() else {
            backupMessage = "The backup was not made because unsaved changes could not be saved."
            return false
        }

        isLibraryLocked = true
        let lastChange = latestChangeDate()
        closeStore()
        var failure: Error?
        do {
            _ = try await LibraryBackupService.createSnapshot(of: location, kind: kind, now: clock(), lastChangeAt: lastChange)
            if kind == .automatic {
                try LibraryBackupService.pruneAutomaticBackups(in: location)
            }
        } catch {
            failure = error
        }
        isLibraryLocked = false
        await reopenAfterOperation(location)

        if let failure {
            backupMessage = Self.message(for: failure)
            return false
        }
        backupMessage = nil
        refreshBackups()
        await flushPendingDrafts()
        return true
    }

    /// The newest modification or deletion in the loaded library. Automatic backups compare against it.
    private func latestChangeDate() -> Date? {
        let noteDates = (notes + deletedNotes).flatMap { [$0.modifiedAt, $0.deletedAt].compactMap { $0 } }
        let folderDates = folders.map(\.modifiedAt)
        return (noteDates + folderDates).max()
    }

    /// Detaches the store so SQLite releases its files. Drafts stay in memory; they are only dropped by a restore.
    private func closeStore() {
        if let container {
            do {
                try CoreDataStack.close(container)
            } catch {
                backupMessage = Self.message(for: error)
            }
        }
        container = nil
        store = nil
    }

    /// Reopens the library after a lock. A failure moves the app to the store-open recovery screen.
    private func reopenAfterOperation(_ location: LibraryLocation) async {
        do {
            let reopened = try await CoreDataStack.openContainer(at: location)
            container = reopened
            store = makeStore(for: reopened)
            try await refresh()
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// After a restore, every draft refers to text that was just replaced. A pre-restore backup already saved
    /// the drafts that mattered, so they are dropped rather than written over the restored library.
    private func resetDraftState() {
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks = [:]
        drafts = [:]
        draftRevisions = [:]
        savedDraftRevisions = [:]
        firstUnsavedEdit = [:]
        saveFailures = [:]
        savingNoteIDs = []
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
        applyListOrder()
    }

    /// Changing folders first saves pending text. If the save fails, the selection stays where it is.
    func requestSidebarSelection(_ selection: SidebarSelection?) async {
        if hasUnsavedChanges {
            guard await flushPendingDrafts() else { return }
        }
        sidebarSelection = selection
        dropSelectionOutsideVisibleNotes()
    }

    /// Number of active notes in a folder, for the sidebar badges.
    func noteCount(inFolder folderID: UUID) -> Int {
        notes.reduce(0) { $0 + ($1.folderID == folderID ? 1 : 0) }
    }

    /// Clears the note selection when the note is no longer visible, so the editor never shows a hidden note.
    private func dropSelectionOutsideVisibleNotes() {
        if let selectedNoteID, !visibleNotes.contains(where: { $0.id == selectedNoteID }) {
            self.selectedNoteID = nil
        }
    }

    /// Re-applies the list order. Called when focus leaves a note, when the sort changes, and after structural
    /// changes, never while a note is being typed in, so rows do not jump under the cursor.
    private func applyListOrder() {
        let order = sortOrder
        notes.sort { NoteSnapshot.listOrder($0, $1, by: order) }
    }

    /// Removes a user folder. Its notes move to Notes, which is the only effect: nothing is deleted. Pending text is saved first.
    @discardableResult
    func deleteFolder(_ folderID: UUID) async -> Bool {
        guard let store = activeStore else { return false }
        guard await flushPendingDrafts() else {
            operationError = "The folder could not be removed because unsaved changes could not be saved."
            return false
        }
        do {
            try await store.deleteFolder(id: folderID)
            if sidebarSelection == .folder(folderID) {
                sidebarSelection = .allNotes
            }
            try await refresh()
            dropSelectionOutsideVisibleNotes()
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    /// Permanently removes trashed notes. A backup is made first. If the backup cannot be made, nothing is deleted.
    @discardableResult
    func permanentlyDeleteNotes(_ noteIDs: [UUID]) async -> Bool {
        guard !noteIDs.isEmpty else { return false }
        guard await flushPendingDrafts() else {
            operationError = "Nothing was deleted because unsaved changes could not be saved."
            return false
        }
        guard await takeBackup(kind: .preDeletion) else {
            operationError = "Nothing was deleted because the backup could not be made. \(backupMessage ?? "")"
            return false
        }
        // The backup reopens the store, so fetch the current one now.
        guard let store = activeStore else { return false }
        do {
            for noteID in noteIDs {
                guard let note = deletedNotes.first(where: { $0.id == noteID }) else { continue }
                try await store.permanentlyDeleteNote(id: noteID, expectedRevision: note.revision)
            }
            try await refresh()
            dropSelectionOutsideVisibleNotes()
            return true
        } catch {
            operationError = Self.message(for: error)
            try? await refresh()
            return false
        }
    }

    /// Empties Recently Deleted after a backup.
    @discardableResult
    func emptyRecentlyDeleted() async -> Bool {
        await permanentlyDeleteNotes(deletedNotes.map(\.id))
    }

    /// Pins or unpins a note. Pending text is saved first, so the revision the store checks is current.
    @discardableResult
    func setPinned(_ noteID: UUID, _ isPinned: Bool) async -> Bool {
        guard let store = activeStore else { return false }
        guard await flushPendingDrafts() else {
            operationError = "The note's pin could not be changed because its unsaved changes could not be saved."
            return false
        }
        guard let note = notes.first(where: { $0.id == noteID }) else {
            operationError = Self.message(for: LibraryError.noteNotFound(noteID))
            return false
        }
        do {
            let updated = try await store.setNotePinned(id: noteID, expectedRevision: note.revision, isPinned: isPinned)
            replaceNote(updated)
            applyListOrder()
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
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
        self.location = location
        do {
            // Finish or undo a restore that was interrupted before the library opens, then upgrade an older library.
            try await LibraryRestoreService.recoverInterruptedRestore(at: location)
            try await LibraryMigrationService.migrateIfNeeded(location)
            let container = try await CoreDataStack.openContainer(at: location)
            self.container = container
            await load(store: makeStore(for: container))
            refreshBackups()
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func makeStore(for container: NSPersistentContainer) -> NoteStore {
        // The repository and the model share one clock, so modification dates and backup times are comparable.
        let clock = self.clock
        var store: NoteStore = LibraryRepository(container: container, now: { clock() })
        #if DEBUG
        if ProcessInfo.processInfo.environment["JAASNOTES_TEST_FAIL_SAVES"] != nil {
            store = DebugSaveFailureStore(base: store)
        }
        #endif
        return store
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
        guard phase == .ready, let store = activeStore, let defaultFolder = folders.first(where: \.isDefault) else { return }
        guard await flushPendingDrafts() else { return }

        let folderID: UUID
        if case .folder(let selectedFolderID) = sidebarSelection {
            folderID = selectedFolderID
        } else {
            folderID = defaultFolder.id
        }

        do {
            let note = try await store.createNote(inFolder: folderID, title: "", bodyPlainText: "")
            // A new note is empty, so a search would hide it. Clear the search so the editor and list agree.
            clearSearch()
            // Creating a note from Recently Deleted moves the view to Notes, so the new note is visible.
            if isShowingRecentlyDeleted {
                sidebarSelection = .allNotes
            }
            try await refresh()
            selectedNoteID = note.id
            titleFocusRequest = note.id
        } catch {
            operationError = Self.message(for: error)
        }
    }

    /// Moves a note to Recently Deleted. Pending text is saved first. If that save fails, nothing is trashed.
    /// Selection moves to the neighboring note, so the editor never goes blank while the list has notes.
    @discardableResult
    func trashNote(_ noteID: UUID) async -> Bool {
        guard let store = activeStore else { return false }
        guard await flushPendingDrafts() else {
            operationError = "The note could not be moved to Recently Deleted because its unsaved changes could not be saved."
            return false
        }
        guard let note = notes.first(where: { $0.id == noteID }) else {
            operationError = Self.message(for: LibraryError.noteNotFound(noteID))
            return false
        }
        let neighbor = neighborOf(noteID)
        do {
            _ = try await store.trashNote(id: noteID, expectedRevision: note.revision)
            try await refresh()
            if selectedNoteID == noteID {
                selectedNoteID = neighbor
            }
            dropSelectionOutsideVisibleNotes()
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    /// Returns a trashed note to its folder. Restoring does not change its content or modification date.
    @discardableResult
    func restoreNote(_ noteID: UUID) async -> Bool {
        guard let store = activeStore else { return false }
        guard let note = deletedNotes.first(where: { $0.id == noteID }) else {
            operationError = Self.message(for: LibraryError.noteNotFound(noteID))
            return false
        }
        do {
            _ = try await store.restoreNote(id: noteID, expectedRevision: note.revision)
            try await refresh()
            dropSelectionOutsideVisibleNotes()
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    /// The note after `noteID` in the list, or before it when it is last. Nil when it is the only note.
    private func neighborOf(_ noteID: UUID) -> UUID? {
        let list = listedNotes
        guard let index = list.firstIndex(where: { $0.id == noteID }) else { return nil }
        if index + 1 < list.count {
            return list[index + 1].id
        }
        return index > 0 ? list[index - 1].id : nil
    }

    /// Creates a folder and selects it. Errors are thrown so the sheet can show them inline and stay open.
    @discardableResult
    func createFolder(named name: String) async throws -> FolderSnapshot {
        let store = try openStore()
        let folder = try await store.createFolder(named: name)
        try await refresh()
        await requestSidebarSelection(.folder(folder.id))
        return folder
    }

    /// Renames a folder. Errors are thrown so the sheet can show them inline and stay open.
    func renameFolder(_ folderID: UUID, to name: String) async throws {
        let store = try openStore()
        _ = try await store.renameFolder(id: folderID, to: name)
        try await refresh()
    }

    /// Moves a note to another folder. Pending text is saved first. If that save fails, nothing moves.
    /// Returns false when the move did not happen; the reason is reported through `operationError`.
    @discardableResult
    func moveNote(_ noteID: UUID, toFolder folderID: UUID) async -> Bool {
        guard let store = activeStore else { return false }
        guard await flushPendingDrafts() else {
            operationError = "The note could not be moved because its unsaved changes could not be saved."
            return false
        }
        guard let note = notes.first(where: { $0.id == noteID }) else {
            operationError = Self.message(for: LibraryError.noteNotFound(noteID))
            return false
        }
        do {
            let moved = try await store.moveNote(id: noteID, expectedRevision: note.revision, toFolderID: folderID)
            replaceNote(moved)
            try await refresh()
            dropSelectionOutsideVisibleNotes()
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    private func openStore() throws -> NoteStore {
        guard phase == .ready, let store = activeStore else {
            throw LibraryError.saveFailed("The library is not open yet.")
        }
        return store
    }

    private func refresh() async throws {
        guard let store = activeStore else { return }
        folders = try await store.folders()
        notes = try await store.activeNotes(inFolder: nil)
        deletedNotes = try await store.deletedNotes()
        applyListOrder()
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
