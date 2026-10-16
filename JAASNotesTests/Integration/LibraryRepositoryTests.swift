import CoreData
import XCTest
@testable import JAASNotes

/// Uses real SQLite stores in unique temporary directories. In-memory stores cannot prove restart durability.
final class LibraryRepositoryTests: XCTestCase {
    private var root: URL!
    private var location: LibraryLocation!
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Opens a fresh container and repository for the test library.
    private func openRepository() async throws -> (LibraryRepository, NSPersistentContainer) {
        let container = try await CoreDataStack.openContainer(at: location)
        let date = fixedDate
        let repository = LibraryRepository(container: container, now: { date })
        return (repository, container)
    }

    // MARK: - First launch

    func testFirstLaunchCreatesMetadataAndOneDefaultFolder() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }

        let metadata = try await repository.initializeLibraryIfNeeded()
        let folders = try await repository.folders()

        XCTAssertEqual(metadata.formatVersion, LibraryRepository.currentFormatVersion)
        XCTAssertEqual(metadata.createdAt, fixedDate)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.name, "Notes")
        XCTAssertEqual(folders.first?.isDefault, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.storeURL.path))
    }

    func testRepeatedInitializationDoesNotDuplicateLibraryState() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }

        let first = try await repository.initializeLibraryIfNeeded()
        let second = try await repository.initializeLibraryIfNeeded()
        let folders = try await repository.folders()

        XCTAssertEqual(first, second)
        XCTAssertEqual(folders.filter(\.isDefault).count, 1)
        XCTAssertEqual(folders.count, 1)
    }

    func testNoMetadataBeforeInitialization() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }

        let metadata = try await repository.libraryMetadata()
        XCTAssertNil(metadata)
    }

    // MARK: - Persistence across stack recreation

    func testLibraryAndNotesSurviveReopeningTheStore() async throws {
        let createdNote: NoteSnapshot
        let libraryID: UUID
        do {
            let (repository, container) = try await openRepository()
            libraryID = try await repository.initializeLibraryIfNeeded().libraryID
            let folder = try await repository.createFolder(named: "Journal")
            createdNote = try await repository.createNote(
                inFolder: folder.id,
                title: "Morning",
                bodyPlainText: "Coffee first."
            )
            try CoreDataStack.close(container)
        }

        let (reopened, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }

        let metadata = try await reopened.initializeLibraryIfNeeded()
        let folders = try await reopened.folders()
        let notes = try await reopened.activeNotes(inFolder: nil)

        XCTAssertEqual(metadata.libraryID, libraryID)
        XCTAssertEqual(folders.map(\.name), ["Notes", "Journal"])
        XCTAssertEqual(notes, [createdNote])
    }

    // MARK: - Folder invariants

    func testDuplicateFolderNamesAreRejectedIgnoringCaseAndDiacritics() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()

        _ = try await repository.createFolder(named: "Café")

        await assertThrowsLibraryError(.duplicateFolderName) {
            _ = try await repository.createFolder(named: "cafe")
        }
        await assertThrowsLibraryError(.duplicateFolderName) {
            _ = try await repository.createFolder(named: "NOTES")
        }
        let folderCount = try await repository.folders().count
        XCTAssertEqual(folderCount, 2)
    }

    func testInvalidFolderNamesAreRejectedWithoutChangingData() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()

        await assertThrowsLibraryError(.emptyFolderName) {
            _ = try await repository.createFolder(named: "   ")
        }
        await assertThrowsLibraryError(.reservedFolderName) {
            _ = try await repository.createFolder(named: "All Notes")
        }
        let folderCount = try await repository.folders().count
        XCTAssertEqual(folderCount, 1)
    }

    // MARK: - Note invariants

    func testNoteRequiresExistingFolder() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()

        let missing = UUID()
        await assertThrowsLibraryError(.folderNotFound(missing)) {
            _ = try await repository.createNote(inFolder: missing, title: "Orphan", bodyPlainText: "")
        }
        let notes = try await repository.activeNotes(inFolder: nil)
        XCTAssertTrue(notes.isEmpty)
    }

    func testNewNoteStartsAtRevisionOneWithUniqueIdentity() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id

        let first = try await repository.createNote(inFolder: folderID, title: "", bodyPlainText: "")
        let second = try await repository.createNote(inFolder: folderID, title: "", bodyPlainText: "")

        XCTAssertEqual(first.revision, 1)
        XCTAssertNil(first.deletedAt)
        XCTAssertEqual(first.folderID, folderID)
        XCTAssertNotEqual(first.id, second.id)
        let noteCount = try await repository.activeNotes(inFolder: folderID).count
        XCTAssertEqual(noteCount, 2)
    }

    func testUnicodeTitleAndBodyAreStoredLosslessly() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id

        let title = "Café 🧪 日本語 مرحبا"
        let body = "Decomposed e\u{0301} and emoji 👩🏽‍💻\nLine two"
        _ = try await repository.createNote(inFolder: folderID, title: title, bodyPlainText: body)

        let stored = try await repository.activeNotes(inFolder: nil).first
        XCTAssertEqual(stored.map { Array($0.title.unicodeScalars) }, Array(title.unicodeScalars))
        XCTAssertEqual(stored.map { Array($0.bodyPlainText.unicodeScalars) }, Array(body.unicodeScalars))
    }

    // MARK: - Saving edits

    func testSavingIdenticalTextChangesNothing() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let created = try await repository.createNote(inFolder: folderID, title: "Same", bodyPlainText: "Text")

        let later = fixedDate.addingTimeInterval(60)
        let laterRepository = LibraryRepository(container: container, now: { later })
        let saved = try await laterRepository.updateNote(id: created.id, expectedRevision: 1, title: "Same", bodyPlainText: "Text")

        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.modifiedAt, fixedDate)
    }

    func testChangedTextIncrementsRevisionAndModificationDate() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let created = try await repository.createNote(inFolder: folderID, title: "", bodyPlainText: "")

        let later = fixedDate.addingTimeInterval(60)
        let laterRepository = LibraryRepository(container: container, now: { later })
        let saved = try await laterRepository.updateNote(id: created.id, expectedRevision: 1, title: "New", bodyPlainText: "Body")

        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(saved.modifiedAt, later)
        XCTAssertEqual(saved.createdAt, fixedDate)
        XCTAssertEqual(saved.title, "New")
    }

    func testStaleRevisionIsRejectedWithoutChangingData() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let created = try await repository.createNote(inFolder: folderID, title: "Original", bodyPlainText: "")

        await assertThrowsLibraryError(.revisionConflict(created.id)) {
            _ = try await repository.updateNote(id: created.id, expectedRevision: 7, title: "Overwrite", bodyPlainText: "")
        }
        let stored = try await repository.activeNotes(inFolder: nil)
        XCTAssertEqual(stored.first?.title, "Original")
        XCTAssertEqual(stored.first?.revision, 1)
    }

    func testUpdatingAMissingNoteIsReported() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let missing = UUID()

        await assertThrowsLibraryError(.noteNotFound(missing)) {
            _ = try await repository.updateNote(id: missing, expectedRevision: 1, title: "", bodyPlainText: "")
        }
    }

    // MARK: - Helpers

    private func assertThrowsLibraryError(
        _ expected: LibraryError,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LibraryError, expected, file: file, line: line)
        }
    }
}

// MARK: - Folder rename, note moves, and ordering (01-05)

final class FolderAndMoveRepositoryTests: XCTestCase {
    private var root: URL!
    private var location: LibraryLocation!
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let laterDate = Date(timeIntervalSince1970: 1_700_003_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func openRepository(at date: Date? = nil) async throws -> (LibraryRepository, NSPersistentContainer) {
        let container = try await CoreDataStack.openContainer(at: location)
        let stamp = date ?? createdAt
        return (LibraryRepository(container: container, now: { stamp }), container)
    }

    private func defaultFolderID(_ repository: LibraryRepository) async throws -> UUID {
        try await repository.folders().first { $0.isDefault }!.id
    }

    func testRenamedFolderPersistsAndKeepsUniqueness() async throws {
        var (repository, container) = try await openRepository()
        _ = try await repository.initializeLibraryIfNeeded()
        let work = try await repository.createFolder(named: "Work")
        _ = try await repository.renameFolder(id: work.id, to: "Projects")
        try CoreDataStack.close(container)

        (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        let names = try await repository.folders().map(\.name)
        XCTAssertEqual(names, ["Notes", "Projects"])

        do {
            _ = try await repository.createFolder(named: "projects")
            XCTFail("A renamed folder must keep its uniqueness rule after reopen.")
        } catch LibraryError.duplicateFolderName {
        }
    }

    func testRenameToCaseVariantOfItselfIsAllowed() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let work = try await repository.createFolder(named: "Work")

        let renamed = try await repository.renameFolder(id: work.id, to: "WORK")
        XCTAssertEqual(renamed.name, "WORK")
    }

    func testRenameToAnotherFoldersNameIsRejectedAndLeavesBothUnchanged() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        _ = try await repository.createFolder(named: "Work")
        let home = try await repository.createFolder(named: "Home")

        do {
            _ = try await repository.renameFolder(id: home.id, to: "  work ")
            XCTFail("Duplicate names must be rejected.")
        } catch LibraryError.duplicateFolderName {
        }
        let names = try await repository.folders().map(\.name)
        // Folders sort by normalized name after the default folder.
        XCTAssertEqual(names, ["Notes", "Home", "Work"])
    }

    func testDefaultFolderCannotBeRenamed() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await defaultFolderID(repository)

        do {
            _ = try await repository.renameFolder(id: defaultID, to: "Inbox")
            XCTFail("The Notes folder is fixed.")
        } catch LibraryError.defaultFolderIsFixed {
        }
        let folders = try await repository.folders()
        XCTAssertEqual(folders.first?.name, "Notes")
    }

    func testRenameRejectsEmptyAndReservedNames() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let work = try await repository.createFolder(named: "Work")

        await XCTAssertThrowsLibraryError(LibraryError.emptyFolderName) {
            _ = try await repository.renameFolder(id: work.id, to: "   ")
        }
        await XCTAssertThrowsLibraryError(LibraryError.reservedFolderName) {
            _ = try await repository.renameFolder(id: work.id, to: "All Notes")
        }
        let name = try await repository.folders().first { $0.id == work.id }?.name
        XCTAssertEqual(name, "Work")
    }

    func testMovePersistsAcrossReopenAndCountsAsAChange() async throws {
        var (repository, container) = try await openRepository()
        _ = try await repository.initializeLibraryIfNeeded()
        let work = try await repository.createFolder(named: "Work")
        let defaultID = try await defaultFolderID(repository)
        let note = try await repository.createNote(inFolder: defaultID, title: "Plan 🗂️", bodyPlainText: "Línea")
        try CoreDataStack.close(container)

        let laterRepository: LibraryRepository
        (laterRepository, container) = try await openRepository(at: laterDate)
        let moved = try await laterRepository.moveNote(id: note.id, expectedRevision: note.revision, toFolderID: work.id)
        XCTAssertEqual(moved.folderID, work.id)
        XCTAssertEqual(moved.revision, note.revision + 1)
        XCTAssertEqual(moved.modifiedAt, laterDate)
        XCTAssertEqual(moved.title, "Plan 🗂️")
        XCTAssertEqual(moved.bodyPlainText, "Línea")
        try CoreDataStack.close(container)

        (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        let stored = try await repository.activeNotes(inFolder: work.id)
        XCTAssertEqual(stored.map(\.id), [note.id])
        XCTAssertEqual(stored.first?.revision, note.revision + 1)
    }

    func testMoveIntoCurrentFolderChangesNothing() async throws {
        let (repository, container) = try await openRepository(at: laterDate)
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await defaultFolderID(repository)
        let note = try await repository.createNote(inFolder: defaultID, title: "A", bodyPlainText: "")

        let same = try await repository.moveNote(id: note.id, expectedRevision: note.revision, toFolderID: defaultID)
        XCTAssertEqual(same, note)
    }

    func testMoveWithStaleRevisionOrMissingTargetLeavesNoteUnchanged() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await defaultFolderID(repository)
        let work = try await repository.createFolder(named: "Work")
        let note = try await repository.createNote(inFolder: defaultID, title: "A", bodyPlainText: "")

        await XCTAssertThrowsLibraryError(LibraryError.revisionConflict(note.id)) {
            _ = try await repository.moveNote(id: note.id, expectedRevision: note.revision + 5, toFolderID: work.id)
        }
        let missingFolderID = UUID()
        await XCTAssertThrowsLibraryError(LibraryError.folderNotFound(missingFolderID)) {
            _ = try await repository.moveNote(id: note.id, expectedRevision: note.revision, toFolderID: missingFolderID)
        }
        let stored = try await repository.activeNotes(inFolder: defaultID)
        XCTAssertEqual(stored, [note])
    }

    func testListOrderIsNewestFirstWithStableTieBreaker() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultID = try await defaultFolderID(repository)
        let first = try await repository.createNote(inFolder: defaultID, title: "First", bodyPlainText: "")
        let second = try await repository.createNote(inFolder: defaultID, title: "Second", bodyPlainText: "")

        let order = try await repository.activeNotes(inFolder: nil).map(\.id)
        // Both notes share the same timestamp, so the UUID string decides their order, every time.
        let expected = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        XCTAssertEqual(order, expected)
        let repeatedOrder = try await repository.activeNotes(inFolder: nil).map(\.id)
        XCTAssertEqual(repeatedOrder, order)
    }
}

/// Asserts that an async throwing block throws the given library error.
private func XCTAssertThrowsLibraryError(
    _ expected: LibraryError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(expected).", file: file, line: line)
    } catch let error as LibraryError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error).", file: file, line: line)
    }
}

// MARK: - Literal search (01-06)

final class SearchRepositoryTests: XCTestCase {
    private var root: URL!
    private var location: LibraryLocation!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testSearchMatchesTitleAndBodyIgnoringCaseAndDiacritics() async throws {
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let titled = try await repository.createNote(inFolder: folderID, title: "Café de Mañana", bodyPlainText: "")
        let bodied = try await repository.createNote(inFolder: folderID, title: "Otra", bodyPlainText: "日本語のメモ 🧪")
        _ = try await repository.createNote(inFolder: folderID, title: "Unrelated", bodyPlainText: "nothing here")

        let cafe = try await repository.searchActiveNotes(matching: "CAFE").map(\.id)
        XCTAssertEqual(cafe, [titled.id], "Title matches ignore case and diacritics.")

        let manana = try await repository.searchActiveNotes(matching: "manana").map(\.id)
        XCTAssertEqual(manana, [titled.id])

        let japanese = try await repository.searchActiveNotes(matching: "日本語").map(\.id)
        XCTAssertEqual(japanese, [bodied.id], "Body matches preserve Unicode.")

        let emoji = try await repository.searchActiveNotes(matching: "🧪").map(\.id)
        XCTAssertEqual(emoji, [bodied.id])
    }

    func testSearchIsLiteralNotPatternMatching() async throws {
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        _ = try await repository.createNote(inFolder: folderID, title: "abc", bodyPlainText: "100% done")

        for pattern in ["a.c", "*", "a%c", "\\", "[a]"] {
            let results = try await repository.searchActiveNotes(matching: pattern)
            XCTAssertTrue(results.isEmpty, "\"\(pattern)\" must be searched literally, not as a pattern.")
        }
        // "%" is an ordinary character here: it finds the literal percent sign and nothing else.
        let percent = try await repository.searchActiveNotes(matching: "%")
        XCTAssertEqual(percent.count, 1)
    }
}

// MARK: - Soft delete and restore (01-07)

final class TrashRepositoryTests: XCTestCase {
    private var root: URL!
    private var location: LibraryLocation!
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let deletedAt = Date(timeIntervalSince1970: 1_700_007_200)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        location = LibraryLocation(rootURL: root)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func openRepository(at date: Date? = nil) async throws -> (LibraryRepository, NSPersistentContainer) {
        let container = try await CoreDataStack.openContainer(at: location)
        let stamp = date ?? createdAt
        return (LibraryRepository(container: container, now: { stamp }), container)
    }

    func testTrashKeepsContentFolderAndModificationDateThroughReopen() async throws {
        var (repository, container) = try await openRepository()
        _ = try await repository.initializeLibraryIfNeeded()
        let work = try await repository.createFolder(named: "Work")
        let note = try await repository.createNote(inFolder: work.id, title: "Keep me 🧪", bodyPlainText: "Línea")
        try CoreDataStack.close(container)

        (repository, container) = try await openRepository(at: deletedAt)
        let trashed = try await repository.trashNote(id: note.id, expectedRevision: note.revision)
        XCTAssertEqual(trashed.deletedAt, deletedAt)
        XCTAssertEqual(trashed.revision, note.revision + 1)
        XCTAssertEqual(trashed.modifiedAt, note.modifiedAt, "Trashing must not change the modification date.")
        XCTAssertEqual(trashed.folderID, work.id)
        XCTAssertEqual(trashed.title, "Keep me 🧪")
        try CoreDataStack.close(container)

        (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        let active = try await repository.activeNotes(inFolder: nil)
        XCTAssertTrue(active.isEmpty, "A trashed note must not appear among active notes.")
        let trash = try await repository.deletedNotes()
        XCTAssertEqual(trash, [trashed], "The trashed note must survive relaunch unchanged.")
    }

    func testRestoreReturnsSameIdentityContentAndFolder() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let work = try await repository.createFolder(named: "Work")
        let note = try await repository.createNote(inFolder: work.id, title: "Round trip", bodyPlainText: "Body 日本語")
        let trashed = try await repository.trashNote(id: note.id, expectedRevision: note.revision)

        let restored = try await repository.restoreNote(id: note.id, expectedRevision: trashed.revision)

        XCTAssertEqual(restored.id, note.id)
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.folderID, work.id)
        XCTAssertEqual(restored.title, "Round trip")
        XCTAssertEqual(restored.bodyPlainText, "Body 日本語")
        XCTAssertEqual(restored.modifiedAt, note.modifiedAt)
        XCTAssertEqual(restored.revision, trashed.revision + 1)
        let remainingTrash = try await repository.deletedNotes()
        XCTAssertEqual(remainingTrash, [])
    }

    func testTrashRulesRejectInvalidTransitionsAndStaleRevisions() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let note = try await repository.createNote(inFolder: folderID, title: "A", bodyPlainText: "")

        await XCTAssertThrowsLibraryError(LibraryError.revisionConflict(note.id)) {
            _ = try await repository.trashNote(id: note.id, expectedRevision: note.revision + 3)
        }
        await XCTAssertThrowsLibraryError(LibraryError.noteNotDeleted(note.id)) {
            _ = try await repository.restoreNote(id: note.id, expectedRevision: note.revision)
        }
        let trashed = try await repository.trashNote(id: note.id, expectedRevision: note.revision)
        await XCTAssertThrowsLibraryError(LibraryError.noteAlreadyDeleted(note.id)) {
            _ = try await repository.trashNote(id: note.id, expectedRevision: trashed.revision)
        }
    }

    func testRecentlyDeletedOrdersByDeletionTime() async throws {
        var (repository, container) = try await openRepository()
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let first = try await repository.createNote(inFolder: folderID, title: "First", bodyPlainText: "")
        let second = try await repository.createNote(inFolder: folderID, title: "Second", bodyPlainText: "")
        _ = try await repository.trashNote(id: first.id, expectedRevision: first.revision)
        try CoreDataStack.close(container)

        (repository, container) = try await openRepository(at: deletedAt)
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.trashNote(id: second.id, expectedRevision: second.revision)

        let order = try await repository.deletedNotes().map(\.id)
        XCTAssertEqual(order, [second.id, first.id], "The note deleted last is listed first.")
    }

    func testTrashedNotesAreExcludedFromSearch() async throws {
        let (repository, container) = try await openRepository()
        defer { try? CoreDataStack.close(container) }
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let note = try await repository.createNote(inFolder: folderID, title: "Findable", bodyPlainText: "needle")
        let before = try await repository.searchActiveNotes(matching: "needle").map(\.id)
        XCTAssertEqual(before, [note.id])

        _ = try await repository.trashNote(id: note.id, expectedRevision: note.revision)

        let after = try await repository.searchActiveNotes(matching: "needle")
        XCTAssertTrue(after.isEmpty, "Deleted notes must not appear in active search results.")
    }
}
