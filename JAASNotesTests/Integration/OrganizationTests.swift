import CoreData
import XCTest
@testable import JAASNotes

/// Pinning, sorting, and the preferences behind them (02-02).
@MainActor
final class OrganizationTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        for suite in suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        roots = []
        suites = []
    }

    private func makeLocation() -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-org-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(root)
        return LibraryLocation(rootURL: root)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "org.jaasnotes.tests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func note(_ id: UUID = UUID(), title: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000), created: Date = Date(timeIntervalSince1970: 1_700_000_000), pinned: Bool = false) -> NoteSnapshot {
        NoteSnapshot(id: id, folderID: UUID(), title: title, bodyPlainText: "", createdAt: created, modifiedAt: modified, deletedAt: nil, revision: 1, isPinned: pinned)
    }

    // MARK: - Repository

    func testPinChangesOnlyTheFlagAndRevision() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let original = try await repository.createNote(inFolder: folderID, title: "Pin me", bodyPlainText: "Body")

        let pinned = try await repository.setNotePinned(id: original.id, expectedRevision: original.revision, isPinned: true)

        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.revision, original.revision + 1)
        XCTAssertEqual(pinned.modifiedAt, original.modifiedAt, "Pinning is not a content edit.")
        XCTAssertEqual(pinned.title, "Pin me")
        let same = try await repository.setNotePinned(id: original.id, expectedRevision: pinned.revision, isPinned: true)
        XCTAssertEqual(same.revision, pinned.revision, "Pinning an already pinned note changes nothing.")
        try CoreDataStack.close(container)

        let reopened = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(reopened) }
        let stored = try await LibraryRepository(container: reopened).activeNotes(inFolder: nil)
        XCTAssertEqual(stored.first?.isPinned, true, "The pin survives relaunch.")
    }

    func testPinWithStaleRevisionIsRejected() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let original = try await repository.createNote(inFolder: folderID, title: "A", bodyPlainText: "")

        do {
            _ = try await repository.setNotePinned(id: original.id, expectedRevision: original.revision + 4, isPinned: true)
            XCTFail("A stale pin must be rejected.")
        } catch LibraryError.revisionConflict {
        }
    }

    private func openRepository() async throws -> (LibraryRepository, NSPersistentContainer) {
        let container = try await CoreDataStack.openContainer(at: makeLocation())
        return (LibraryRepository(container: container), container)
    }

    // MARK: - Ordering

    func testPinnedNotesComeFirstInEveryOrder() {
        let older = note(title: "Old", modified: Date(timeIntervalSince1970: 100))
        let newerPinned = note(title: "Pinned", modified: Date(timeIntervalSince1970: 50), pinned: true)
        let ordered = [older, newerPinned].sorted { NoteSnapshot.listOrder($0, $1, by: .modified) }
        XCTAssertEqual(ordered.map(\.title), ["Pinned", "Old"])
        let byTitle = [older, newerPinned].sorted { NoteSnapshot.listOrder($0, $1, by: .title) }
        XCTAssertEqual(byTitle.map(\.title), ["Pinned", "Old"])
    }

    func testSortOrdersByModifiedCreatedAndTitle() {
        let apple = note(title: "apple", modified: Date(timeIntervalSince1970: 300), created: Date(timeIntervalSince1970: 100))
        let zebra = note(title: "Zebra", modified: Date(timeIntervalSince1970: 100), created: Date(timeIntervalSince1970: 300))
        let eclair = note(title: "éclair", modified: Date(timeIntervalSince1970: 200), created: Date(timeIntervalSince1970: 200))
        let all = [zebra, eclair, apple]

        XCTAssertEqual(all.sorted { NoteSnapshot.listOrder($0, $1, by: .modified) }.map(\.title), ["apple", "éclair", "Zebra"])
        XCTAssertEqual(all.sorted { NoteSnapshot.listOrder($0, $1, by: .created) }.map(\.title), ["Zebra", "éclair", "apple"])
        XCTAssertEqual(all.sorted { NoteSnapshot.listOrder($0, $1, by: .title) }.map(\.title), ["apple", "éclair", "Zebra"])
    }

    func testEqualKeysUseAStableTieBreaker() {
        let first = note(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Same")
        let second = note(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Same")
        for order in NoteSortOrder.allCases {
            XCTAssertEqual([second, first].sorted { NoteSnapshot.listOrder($0, $1, by: order) }.map(\.id), [first.id, second.id])
        }
    }

    // MARK: - Model: preferences and state

    func testSortAndPinSurviveRelaunch() async throws {
        let location = makeLocation()
        let defaults = makeDefaults()
        let first = LibraryModel(defaults: defaults)
        await first.load(at: location)
        await first.createNote()
        let plainID = try XCTUnwrap(first.selectedNoteID)
        first.updateDraft(for: plainID, title: "Plain")
        await first.flushPendingDrafts()
        await first.createNote()
        let pinnedID = try XCTUnwrap(first.selectedNoteID)
        first.updateDraft(for: pinnedID, title: "Pinned")
        await first.flushPendingDrafts()
        let pinned = await first.setPinned(pinnedID, true)
        XCTAssertTrue(pinned)
        first.sortOrder = .title

        let relaunched = LibraryModel(defaults: defaults)
        await relaunched.load(at: location)

        XCTAssertEqual(relaunched.sortOrder, .title, "The sort choice survives relaunch.")
        XCTAssertEqual(relaunched.notes.first?.id, pinnedID, "Pinned notes stay first after relaunch.")
        XCTAssertEqual(relaunched.notes.first?.isPinned, true)
    }

    func testSortingKeepsUnsavedTextAndSelection() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Unsaved while sorting")

        model.sortOrder = .title

        XCTAssertTrue(model.hasUnsavedChanges, "Re-sorting must not clear unsaved text.")
        XCTAssertEqual(model.selectedNoteID, fixture.noteID, "Re-sorting must not move the selection.")
        XCTAssertEqual(model.draft(for: try XCTUnwrap(model.notes.first)).title, "Unsaved while sorting")
        model.sortOrder = .modified
    }

    func testPinIsRefusedWhileSaveFailsAndTheNoteStaysUnpinned() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Pending")
        await fixture.faulty.failNextUpdates(1)

        let pinned = await model.setPinned(fixture.noteID, true)

        XCTAssertFalse(pinned)
        XCTAssertFalse(model.notes.first { $0.id == fixture.noteID }?.isPinned ?? true)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    // MARK: - Folder removal and permanent deletion (02-03)

    func testDeletingAFolderMovesActiveAndTrashedNotesToNotes() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await repository.folders()[0].id
        let work = try await repository.createFolder(named: "Work")
        let active = try await repository.createNote(inFolder: work.id, title: "Active", bodyPlainText: "")
        let toTrash = try await repository.createNote(inFolder: work.id, title: "Trashed", bodyPlainText: "")
        let trashed = try await repository.trashNote(id: toTrash.id, expectedRevision: toTrash.revision)
        try await repository.deleteFolder(id: work.id)
        let folderNames = try await repository.folders().map(\.name)
        XCTAssertEqual(folderNames, ["Notes"])
        try CoreDataStack.close(container)

        let reopened = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(reopened) }
        let reopenedRepository = LibraryRepository(container: reopened)
        let activeNotes = try await reopenedRepository.activeNotes(inFolder: defaultID)
        XCTAssertEqual(activeNotes.map(\.title), ["Active"])
        XCTAssertGreaterThan(activeNotes[0].revision, active.revision)
        let trashedAfter = try await reopenedRepository.deletedNotes()
        XCTAssertEqual(trashedAfter.map(\.id), [trashed.id], "A trashed note survives folder removal.")
        XCTAssertEqual(trashedAfter[0].folderID, defaultID)
        XCTAssertEqual(trashedAfter[0].deletedAt, trashed.deletedAt)
    }

    func testDefaultFolderCannotBeRemovedAndPermanentDeleteNeedsATrashedNote() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await repository.folders()[0].id
        do {
            try await repository.deleteFolder(id: defaultID)
            XCTFail("The default folder is fixed.")
        } catch LibraryError.defaultFolderIsFixed {
        }

        let note = try await repository.createNote(inFolder: defaultID, title: "Active", bodyPlainText: "")
        do {
            try await repository.permanentlyDeleteNote(id: note.id, expectedRevision: note.revision)
            XCTFail("An active note must not be deleted permanently.")
        } catch LibraryError.noteNotDeleted {
        }
        let stillThere = try await repository.activeNotes(inFolder: defaultID)
        XCTAssertEqual(stillThere.count, 1)
    }

    func testPermanentDeleteRemovesOnlyTheTrashedNoteAndSurvivesReopen() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await repository.folders()[0].id
        let keep = try await repository.createNote(inFolder: defaultID, title: "Keep", bodyPlainText: "")
        let gone = try await repository.createNote(inFolder: defaultID, title: "Gone", bodyPlainText: "")
        let trashed = try await repository.trashNote(id: gone.id, expectedRevision: gone.revision)
        try await repository.permanentlyDeleteNote(id: gone.id, expectedRevision: trashed.revision)
        try CoreDataStack.close(container)

        let reopened = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(reopened) }
        let reopenedRepository = LibraryRepository(container: reopened)
        let deleted = try await reopenedRepository.deletedNotes()
        let active = try await reopenedRepository.activeNotes(inFolder: nil)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(active.map(\.id), [keep.id])
    }

    func testPermanentDeleteTakesABackupFirst() async throws {
        let location = makeLocation()
        let model = LibraryModel(defaults: makeDefaults())
        await model.load(at: location)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: noteID, title: "To remove")
        await model.flushPendingDrafts()
        let trashed = await model.trashNote(noteID)
        XCTAssertTrue(trashed)

        let deleted = await model.permanentlyDeleteNotes([noteID])

        XCTAssertTrue(deleted)
        XCTAssertTrue(model.deletedNotes.isEmpty)
        XCTAssertTrue(model.backups.contains { $0.kind == .preDeletion }, "A backup is made before deletion.")
    }

    func testPermanentDeleteIsCancelledWhenTheBackupFails() async throws {
        let location = makeLocation()
        let model = LibraryModel(defaults: makeDefaults())
        await model.load(at: location)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: noteID, title: "Must survive")
        await model.flushPendingDrafts()
        _ = await model.trashNote(noteID)

        // A regular file where the Backups folder should be makes the backup fail.
        try Data("blocker".utf8).write(to: LibraryBackupService.backupsDirectory(in: location))
        let deleted = await model.permanentlyDeleteNotes([noteID])

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.deletedNotes.map(\.id), [noteID], "Nothing is deleted when the backup fails.")
        XCTAssertTrue(model.operationError?.contains("Nothing was deleted") ?? false)

        try FileManager.default.removeItem(at: LibraryBackupService.backupsDirectory(in: location))
        let retried = await model.permanentlyDeleteNotes([noteID])
        XCTAssertTrue(retried, "Once the backup works, the deletion can proceed.")
        XCTAssertTrue(model.deletedNotes.isEmpty)
    }

    func testEmptyRecentlyDeletedRemovesOnlyTrashedNotes() async throws {
        let location = makeLocation()
        let model = LibraryModel(defaults: makeDefaults())
        await model.load(at: location)
        await model.createNote()
        let keepID = try XCTUnwrap(model.selectedNoteID)
        await model.createNote()
        let firstTrashID = try XCTUnwrap(model.selectedNoteID)
        _ = await model.trashNote(firstTrashID)
        await model.requestSidebarSelection(.allNotes)
        await model.requestNoteSelection(keepID)
        await model.createNote()
        let secondTrashID = try XCTUnwrap(model.selectedNoteID)
        _ = await model.trashNote(secondTrashID)
        XCTAssertEqual(model.deletedNotes.count, 2)

        let emptied = await model.emptyRecentlyDeleted()

        XCTAssertTrue(emptied)
        XCTAssertTrue(model.deletedNotes.isEmpty)
        XCTAssertTrue(model.notes.contains { $0.id == keepID }, "Active notes are untouched.")
    }

    func testRemovingTheSelectedFolderReturnsToAllNotesWithNoteKept() async throws {
        let location = makeLocation()
        let model = LibraryModel(defaults: makeDefaults())
        await model.load(at: location)
        let work = try await model.createFolder(named: "Work")
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: noteID, title: "Moves to Notes")
        await model.flushPendingDrafts()

        let removed = await model.deleteFolder(work.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(model.sidebarSelection, .allNotes)
        XCTAssertEqual(model.notes.first { $0.id == noteID }?.title, "Moves to Notes")
        XCTAssertEqual(model.folders.map(\.name), ["Notes"])
    }
}

/// Timings on 10,000 synthetic notes. Limits are provisional (plan §8): the test records real timings and fails only
/// when a path is far outside the target. Values are printed to the test log for the progress record.
@MainActor
final class LargeLibraryPerformanceTests: XCTestCase {
    private var root: URL?

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testTenThousandNotesLoadListAndSearchWithinProvisionalLimits() async throws {
        let location = LibraryLocation(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-perf-\(UUID().uuidString)", directoryHint: .isDirectory))
        root = location.rootURL
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id

        // One save for all notes, so setup time does not depend on per-note transactions.
        let context = container.newBackgroundContext()
        try await context.perform {
            let folder = try context.fetch(NSFetchRequest<FolderRecord>(entityName: "Folder")).first { $0.isDefault }!
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<10_000 {
                let note = NSEntityDescription.insertNewObject(forEntityName: "Note", into: context) as! NoteRecord
                note.id = UUID()
                note.title = "Note \(index) " + (index % 100 == 0 ? "needle" : "plain")
                note.bodyPlainText = String(repeating: "Body text for synthetic note \(index). ", count: 6)
                note.createdAt = base.addingTimeInterval(Double(index))
                note.modifiedAt = base.addingTimeInterval(Double(index))
                note.revision = 1
                note.isPinned = index % 250 == 0
                note.folder = folder
            }
            try context.save()
        }
        let inserted = try await repository.activeNotes(inFolder: folderID).count
        XCTAssertEqual(inserted, 10_000)
        try CoreDataStack.close(container)

        let launchStart = Date()
        let model = LibraryModel(defaults: UserDefaults(suiteName: "org.jaasnotes.tests.perf-\(UUID().uuidString)")!)
        await model.load(at: location)
        let launchSeconds = Date().timeIntervalSince(launchStart)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.notes.count, 10_000)

        let sortStart = Date()
        model.sortOrder = .title
        let sortSeconds = Date().timeIntervalSince(sortStart)

        let searchStart = Date()
        model.setSearchText("needle")
        await model.pendingSearch?.value
        let searchSeconds = Date().timeIntervalSince(searchStart)
        XCTAssertEqual(model.listedNotes.count, 100)

        print("PERF launch_load_seconds=\(launchSeconds) sort_seconds=\(sortSeconds) search_seconds_incl_debounce=\(searchSeconds)")
        XCTAssertLessThan(launchSeconds, 5, "Opening 10,000 notes should be well under 5 seconds.")
        XCTAssertLessThan(sortSeconds, 1, "Re-sorting 10,000 notes should be well under 1 second.")
        XCTAssertLessThan(searchSeconds, 2, "Search after the 200 ms debounce should be well under 2 seconds.")
    }
}
