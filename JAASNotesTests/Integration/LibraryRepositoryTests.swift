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
