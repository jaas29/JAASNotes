import CryptoKit
import XCTest
@testable import JAASNotes

/// Attachment import, commit ordering, reconciliation, backups, and deletion against real temporary libraries (04-01).
@MainActor
final class AttachmentTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func makeLocation(_ name: String = "att") -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(root)
        return LibraryLocation(rootURL: root)
    }

    /// A scratch folder outside the library, for source files.
    private func makeScratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Opens a library with one note in the default folder, and returns the store, repository, and note.
    private func openWithNote(_ location: LibraryLocation) async throws -> (container: NSPersistentContainer, repository: LibraryRepository, noteID: UUID, revision: Int64) {
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let note = try await repository.createNote(inFolder: folderID, title: "With files", bodyPlainText: "Body")
        return (container, repository, note.id, note.revision)
    }

    private func payloadFolders(in location: LibraryLocation) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: AttachmentService.attachmentsDirectory(in: location).path)) ?? []
    }

    private func writeSource(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    // MARK: - Import and restart

    func testCopiedBytesSurviveSourceDeletionAndRestart() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        let scratch = makeScratch()
        let data = Data("Résumé 🧾 contents\n".utf8)
        let source = try writeSource(data, named: "Résumé 🧾.txt", in: scratch)

        let attachment = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository)
        try FileManager.default.removeItem(at: source)
        try CoreDataStack.close(container)

        XCTAssertEqual(attachment.originalFilename, "Résumé 🧾.txt")
        XCTAssertEqual(attachment.byteCount, Int64(data.count))
        XCTAssertEqual(attachment.sha256, sha256Hex(data))
        XCTAssertEqual(attachment.relativePath, "Attachments/\(attachment.id.uuidString)/payload")

        let reopened = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(reopened) }
        let rows = try await LibraryRepository(container: reopened).attachments(forNote: noteID)
        XCTAssertEqual(rows, [attachment], "The row survives a restart unchanged.")
        let payload = location.libraryDirectoryURL.appending(path: attachment.relativePath, directoryHint: .notDirectory)
        XCTAssertEqual(try Data(contentsOf: payload), data, "The bytes survive the source being deleted.")
    }

    func testAttachingDoesNotChangeTheNoteRevision() async throws {
        let location = makeLocation()
        let (container, repository, noteID, revision) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let source = try writeSource(Data("x".utf8), named: "a.txt", in: makeScratch())

        _ = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository)

        let folderID = try await repository.folders()[0].id
        let note = try await repository.activeNotes(inFolder: folderID).first { $0.id == noteID }
        XCTAssertEqual(note?.revision, revision, "An open editor's next save must not become a conflict.")
    }

    func testAttachmentsKeepTheirDisplayOrder() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let scratch = makeScratch()
        for name in ["one.txt", "two.txt", "three.txt"] {
            let source = try writeSource(Data(name.utf8), named: name, in: scratch)
            _ = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository)
        }

        let rows = try await repository.attachments(forNote: noteID)

        XCTAssertEqual(rows.map(\.originalFilename), ["one.txt", "two.txt", "three.txt"])
        XCTAssertEqual(rows.map(\.displayOrder), [0, 1, 2])
    }

    // MARK: - Failure ordering

    func testFailedCommitLeavesNoRowAndNoPayload() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let store = FailingAttachmentStore(base: repository)
        await store.failNextCreate()
        let source = try writeSource(Data("payload".utf8), named: "a.txt", in: makeScratch())

        do {
            _ = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: store)
            XCTFail("An injected commit failure must fail the import.")
        } catch LibraryError.saveFailed {
        }

        let rows = try await repository.allAttachments()
        XCTAssertTrue(rows.isEmpty, "No row is acknowledged.")
        XCTAssertTrue(payloadFolders(in: location).isEmpty, "The moved bytes are removed with the failed commit.")
    }

    func testInterruptionAfterTheMoveLeavesBytesThatReconciliationQuarantines() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let source = try writeSource(Data("orphan".utf8), named: "a.txt", in: makeScratch())

        do {
            _ = try await AttachmentService.importFile(
                at: source, noteID: noteID, location: location, store: repository, fault: .afterPayloadMoved
            )
            XCTFail("The interruption must stop the import.")
        } catch LibraryBackupError.simulatedInterruption {
        }
        let value1 = try await repository.allAttachments().isEmpty
        XCTAssertTrue(value1, "The row was never committed.")
        XCTAssertEqual(payloadFolders(in: location).count, 1, "Bytes with no row are left for reconciliation.")

        let result = try await AttachmentService.reconcile(location: location, store: repository)

        XCTAssertEqual(result.quarantinedFolderNames.count, 1)
        XCTAssertTrue(payloadFolders(in: location).isEmpty, "The orphan is no longer in the library.")
        let quarantined = LibraryBackupService.recoveryDirectory(in: location).appending(path: "orphaned-attachments", directoryHint: .isDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantined.path).count, 1, "It is moved to Recovery, not deleted.")
    }

    func testOversizedFileIsRefusedBeforeAnythingIsWritten() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let source = try writeSource(Data(repeating: 1, count: 11), named: "big.bin", in: makeScratch())

        do {
            _ = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository, maximumBytes: 10)
            XCTFail("A file over the limit must be refused.")
        } catch AttachmentError.tooLarge(let limit) {
            XCTAssertEqual(limit, 10)
        }
        let value2 = try await repository.allAttachments().isEmpty
        XCTAssertTrue(value2)
        XCTAssertTrue(payloadFolders(in: location).isEmpty)
    }

    func testFileAtTheLimitIsAccepted() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let source = try writeSource(Data(repeating: 2, count: 10), named: "edge.bin", in: makeScratch())

        let attachment = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository, maximumBytes: 10)

        XCTAssertEqual(attachment.byteCount, 10)
    }

    func testLinksAndFoldersAreNotCopied() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let scratch = makeScratch()
        let target = try writeSource(Data("target".utf8), named: "target.txt", in: scratch)
        let link = scratch.appending(path: "link.txt", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let folder = scratch.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for source in [link, folder] {
            do {
                _ = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository)
                XCTFail("\(source.lastPathComponent) must not be attached.")
            } catch AttachmentError.notARegularFile {
            }
        }
        let value3 = try await repository.allAttachments().isEmpty
        XCTAssertTrue(value3)
    }

    // MARK: - Reconciliation

    func testMissingPayloadIsReportedAndItsRowIsKept() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let source = try writeSource(Data("keep".utf8), named: "a.txt", in: makeScratch())
        let attachment = try await AttachmentService.importFile(at: source, noteID: noteID, location: location, store: repository)
        try FileManager.default.removeItem(at: location.libraryDirectoryURL.appending(path: attachment.relativePath, directoryHint: .notDirectory))

        let result = try await AttachmentService.reconcile(location: location, store: repository)

        XCTAssertEqual(result.damagedAttachmentIDs, [attachment.id])
        let value4 = try await repository.attachments(forNote: noteID).count
        XCTAssertEqual(value4, 1, "The row is kept, so the missing file can be shown.")
    }

    func testUnsafeStoredPathsAreRefused() {
        XCTAssertTrue(AttachmentService.isSafeRelativePath("Attachments/\(UUID().uuidString)/payload"))
        XCTAssertFalse(AttachmentService.isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(AttachmentService.isSafeRelativePath("Attachments/../Store.sqlite"))
        XCTAssertFalse(AttachmentService.isSafeRelativePath("Attachments/not-a-uuid/payload"))
        XCTAssertFalse(AttachmentService.isSafeRelativePath("Store.sqlite"))
    }

    // MARK: - Backups

    func testBackupAndRestoreCarryAttachmentsWithChecksums() async throws {
        let source = makeLocation("att-source")
        let (container, repository, noteID, _) = try await openWithNote(source)
        let data = Data("backed up".utf8)
        let attachment = try await AttachmentService.importFile(
            at: try writeSource(data, named: "b.txt", in: makeScratch()), noteID: noteID, location: source, store: repository
        )
        try CoreDataStack.close(container)

        let backup = try await LibraryBackupService.createSnapshot(of: source, kind: .manual, now: Date(), lastChangeAt: nil)
        let manifest = try LibraryBackupService.readManifest(in: backup.url)
        XCTAssertEqual(manifest.files[attachment.relativePath], sha256Hex(data), "The payload is checksummed in the manifest.")

        let fresh = makeLocation("att-fresh")
        try await LibraryRestoreService.restore(backup, into: fresh)
        let restored = try await CoreDataStack.openContainer(at: fresh)
        defer { try? CoreDataStack.close(restored) }
        let rows = try await LibraryRepository(container: restored).attachments(forNote: noteID)
        XCTAssertEqual(rows, [attachment])
        XCTAssertEqual(try Data(contentsOf: fresh.libraryDirectoryURL.appending(path: attachment.relativePath, directoryHint: .notDirectory)), data)
    }

    func testDamagedPayloadStopsABackupAndPublishesNothing() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        let attachment = try await AttachmentService.importFile(
            at: try writeSource(Data("good bytes".utf8), named: "c.txt", in: makeScratch()), noteID: noteID, location: location, store: repository
        )
        // Same size, different content: only the checksum can catch this.
        try Data("bad  bytes".utf8).write(to: location.libraryDirectoryURL.appending(path: attachment.relativePath, directoryHint: .notDirectory))
        try CoreDataStack.close(container)

        do {
            _ = try await LibraryBackupService.createSnapshot(of: location, kind: .manual, now: Date(), lastChangeAt: nil)
            XCTFail("A backup of a damaged payload must not be published.")
        } catch LibraryBackupError.validationFailed {
        }
        XCTAssertTrue(try LibraryBackupService.list(in: location).isEmpty)
    }

    // MARK: - Deletion

    func testPermanentDeletionRemovesRowsAndThenThePayload() async throws {
        let location = makeLocation()
        let (container, repository, noteID, _) = try await openWithNote(location)
        defer { try? CoreDataStack.close(container) }
        let attachment = try await AttachmentService.importFile(
            at: try writeSource(Data("gone".utf8), named: "d.txt", in: makeScratch()), noteID: noteID, location: location, store: repository
        )
        let folderID = try await repository.folders()[0].id
        let note = try await repository.activeNotes(inFolder: folderID).first { $0.id == noteID }!
        let trashed = try await repository.trashNote(id: noteID, expectedRevision: note.revision)
        let value5 = try await repository.attachments(forNote: noteID).count
        XCTAssertEqual(value5, 1, "Trashed notes keep their files.")

        try await repository.permanentlyDeleteNote(id: noteID, expectedRevision: trashed.revision)

        let value6 = try await repository.allAttachments().isEmpty
        XCTAssertTrue(value6, "The rows go with the note.")
        XCTAssertFalse(payloadFolders(in: location).isEmpty, "The bytes remain until the row deletion has committed.")
        AttachmentService.removePayloads(of: [attachment.id], location: location)
        XCTAssertTrue(payloadFolders(in: location).isEmpty)
    }
}

/// Wraps the repository and fails the next row commit, to test that no payload is left behind.
actor FailingAttachmentStore: AttachmentStore {
    private let base: LibraryRepository
    private var shouldFailCreate = false

    init(base: LibraryRepository) {
        self.base = base
    }

    func failNextCreate() {
        shouldFailCreate = true
    }

    func createAttachment(_ new: NewAttachment) async throws -> AttachmentSnapshot {
        if shouldFailCreate {
            shouldFailCreate = false
            throw LibraryError.saveFailed("Injected commit failure.")
        }
        return try await base.createAttachment(new)
    }

    func deleteAttachment(id: UUID) async throws {
        try await base.deleteAttachment(id: id)
    }

    func attachments(forNote noteID: UUID) async throws -> [AttachmentSnapshot] {
        try await base.attachments(forNote: noteID)
    }

    func allAttachments() async throws -> [AttachmentSnapshot] {
        try await base.allAttachments()
    }
}
