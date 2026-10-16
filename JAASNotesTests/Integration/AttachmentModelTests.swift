import CryptoKit
import XCTest
@testable import JAASNotes

/// Attachments through the app model: attach, remove, missing files after relaunch, export checks, and permanent deletion (04-02).
@MainActor
final class AttachmentModelTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func makeFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSource(_ text: String, named name: String = "note.txt") throws -> URL {
        let url = makeFolder("src").appending(path: name, directoryHint: .notDirectory)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A model with one note selected and a file attached to it.
    private func openModelWithAttachment() async throws -> (LibraryModel, LibraryLocation, UUID, AttachmentSnapshot) {
        let location = LibraryLocation(rootURL: makeFolder("lib"))
        let model = LibraryModel(sleep: SaveFixture.holdSleep)
        await model.load(at: location)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        let source = try makeSource("hello attachment")
        let attached = await model.attachFile(at: source, to: noteID)
        XCTAssertTrue(attached)
        let attachment = try XCTUnwrap(model.attachments(for: noteID).first)
        return (model, location, noteID, attachment)
    }

    func testAttachedFileAppearsInTheTrayAndSurvivesRelaunch() async throws {
        let (model, location, noteID, attachment) = try await openModelWithAttachment()
        XCTAssertEqual(attachment.originalFilename, "note.txt")
        XCTAssertFalse(model.missingAttachmentIDs.contains(attachment.id))

        let relaunched = LibraryModel(sleep: SaveFixture.holdSleep)
        await relaunched.load(at: location)
        await relaunched.loadAttachments(for: noteID)

        XCTAssertEqual(relaunched.attachments(for: noteID).map(\.id), [attachment.id])
        XCTAssertTrue(relaunched.missingAttachmentIDs.isEmpty)
    }

    func testRemovingAnAttachmentDeletesItsRowAndBytes() async throws {
        let (model, location, noteID, attachment) = try await openModelWithAttachment()
        let file = try XCTUnwrap(model.attachmentFileURL(for: attachment))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let removed = await model.removeAttachment(attachment.id, from: noteID)

        XCTAssertTrue(removed)
        XCTAssertTrue(model.attachments(for: noteID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.libraryDirectoryURL.appending(path: "Attachments/\(attachment.id.uuidString)").path))
    }

    func testMissingBytesAreShownAfterRelaunchAndCannotBeExported() async throws {
        let (model, location, noteID, attachment) = try await openModelWithAttachment()
        let file = try XCTUnwrap(model.attachmentFileURL(for: attachment))
        try FileManager.default.removeItem(at: file)

        let relaunched = LibraryModel(sleep: SaveFixture.holdSleep)
        await relaunched.load(at: location)
        await relaunched.loadAttachments(for: noteID)

        XCTAssertTrue(relaunched.missingAttachmentIDs.contains(attachment.id), "The tray shows the file as missing.")
        let destination = makeFolder("out").appending(path: "copy.txt", directoryHint: .notDirectory)
        XCTAssertFalse(relaunched.exportAttachment(attachment, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotNil(relaunched.operationError)
    }

    func testDamagedBytesAreNeverExported() async throws {
        let (model, _, _, attachment) = try await openModelWithAttachment()
        let file = try XCTUnwrap(model.attachmentFileURL(for: attachment))
        try Data("HELLO ATTACHMENT".utf8).write(to: file)   // same size, different bytes

        let destination = makeFolder("out").appending(path: "copy.txt", directoryHint: .notDirectory)
        XCTAssertFalse(model.exportAttachment(attachment, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportWritesTheCheckedBytes() async throws {
        let (model, _, _, attachment) = try await openModelWithAttachment()
        let destination = makeFolder("out").appending(path: "exported.txt", directoryHint: .notDirectory)

        XCTAssertTrue(model.exportAttachment(attachment, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), Data("hello attachment".utf8))
    }

    func testTrashingKeepsAttachmentsAndPermanentDeletionRemovesTheirBytes() async throws {
        let (model, location, noteID, attachment) = try await openModelWithAttachment()
        let file = try XCTUnwrap(model.attachmentFileURL(for: attachment))

        let trashed = await model.trashNote(noteID)
        XCTAssertTrue(trashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Trashed notes keep their files.")

        let deleted = await model.permanentlyDeleteNotes([noteID])
        XCTAssertTrue(deleted)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Permanent deletion removes the bytes.")
        XCTAssertTrue(model.attachments(for: noteID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.libraryDirectoryURL.appending(path: "Attachments/\(attachment.id.uuidString)").path))
    }
}
