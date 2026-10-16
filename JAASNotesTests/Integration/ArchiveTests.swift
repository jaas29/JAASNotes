import AppKit
import CryptoKit
import XCTest
@testable import JAASNotes

/// Portable archives: export, validated import into a fresh library, collision handling, refused archives, and text files (04-03).
@MainActor
final class ArchiveTests: XCTestCase {
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

    private func makeLocation(_ name: String) -> LibraryLocation {
        LibraryLocation(rootURL: makeFolder(name))
    }

    /// A library with a second folder, a formatted checklist note, a plain note, a trashed note, and an attachment.
    /// Returns the checklist item identities so they can be compared after the round trip.
    private func populate(_ location: LibraryLocation) async throws -> (itemID: UUID, attachmentBytes: Data) {
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let defaultFolder = try await repository.folders()[0].id
        let work = try await repository.createFolder(named: "Work")

        let itemID = UUID()
        let text = NSMutableAttributedString(string: "Packing 🧳\nSocks 日本\nPassport")
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 7))
        let checklist = ChecklistSidecar(items: [ChecklistItem(id: itemID, isChecked: true, location: 11, length: 8)])
        let rich = try await repository.createNote(inFolder: work.id, title: "Trip", bodyPlainText: "")
        _ = try await repository.updateRichNote(
            id: rich.id,
            expectedRevision: rich.revision,
            title: "Trip",
            content: try RichTextCodec.content(from: text, checklist: checklist)
        )
        _ = try await repository.setNotePinned(id: rich.id, expectedRevision: rich.revision + 1, isPinned: true)

        _ = try await repository.createNote(inFolder: defaultFolder, title: "Plain", bodyPlainText: "Just text")
        let trashed = try await repository.createNote(inFolder: defaultFolder, title: "Old", bodyPlainText: "Gone")
        _ = try await repository.trashNote(id: trashed.id, expectedRevision: trashed.revision)

        let bytes = Data("attached bytes \u{1F4CE}".utf8)
        let source = makeFolder("src").appending(path: "file.bin", directoryHint: .notDirectory)
        try bytes.write(to: source)
        _ = try await AttachmentService.importFile(at: source, noteID: rich.id, location: location, store: repository)
        return (itemID, bytes)
    }

    private func export(_ location: LibraryLocation) async throws -> URL {
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let destination = makeFolder("archive").appending(path: "out.jnarchive", directoryHint: .isDirectory)
        _ = try await ArchiveService.export(to: destination, store: LibraryRepository(container: container), location: location)
        return destination
    }

    // MARK: - Round trip

    func testArchiveRoundTripRecreatesNotesFoldersChecklistsAndFilesInAFreshLibrary() async throws {
        let source = makeLocation("archive-source")
        let (itemID, bytes) = try await populate(source)
        let archive = try await export(source)

        let target = makeLocation("archive-target")
        let container = try await CoreDataStack.openContainer(at: target)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let validated = try ArchiveService.read(at: archive, existingFolderNames: [])
        _ = try await ArchiveService.importArchive(validated, location: target, store: repository)

        let folders = try await repository.folders().map(\.name).sorted()
        XCTAssertEqual(folders, ["Notes", "Notes (Imported)", "Work"], "The archive's Notes folder is imported as its own folder.")
        let active = try await repository.activeNotes(inFolder: nil)
        XCTAssertEqual(active.map(\.title).sorted(), ["Plain", "Trip"])
        let value1 = try await repository.deletedNotes().map(\.title)
        XCTAssertEqual(value1, ["Old"], "Recently Deleted is kept.")
        let trip = try XCTUnwrap(active.first { $0.title == "Trip" })
        XCTAssertTrue(trip.isPinned)
        XCTAssertTrue(trip.hasRichContent)
        let body = try await repository.body(of: trip.id)
        guard case .rich(let content) = body else { return XCTFail("The formatted note must come back formatted, got \(body)") }
        XCTAssertEqual(content.plainText, "Packing 🧳\nSocks 日本\nPassport")
        XCTAssertEqual(content.checklist?.items.first?.id, itemID, "Checklist item identity is kept across the archive.")
        XCTAssertEqual(content.checklist?.items.first?.isChecked, true)

        let attachments = try await repository.attachments(forNote: trip.id)
        XCTAssertEqual(attachments.count, 1)
        let copied = try XCTUnwrap(attachments.first)
        XCTAssertEqual(try Data(contentsOf: target.libraryDirectoryURL.appending(path: copied.relativePath, directoryHint: .notDirectory)), bytes)
        XCTAssertEqual(copied.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func testImportingIntoTheSameLibraryAddsNewItemsAndRenamesClashingFolders() async throws {
        let library = makeLocation("archive-same")
        _ = try await populate(library)
        let before = try await snapshotCounts(library)
        let archive = try await export(library)

        let container = try await CoreDataStack.openContainer(at: library)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        let existing = try await repository.folders().map(\.name)
        let validated = try ArchiveService.read(at: archive, existingFolderNames: existing)
        XCTAssertEqual(Set(validated.renamedFolders.map(\.final)), ["Work (Imported)", "Notes (Imported)"])
        _ = try await ArchiveService.importArchive(validated, location: library, store: repository)

        let after = try await snapshotCounts(library, container: container)
        XCTAssertEqual(after.notes, before.notes * 2, "Every note is imported as a new note.")
        XCTAssertEqual(after.folders, before.folders * 2)
        let value2 = try await repository.folders().map(\.name).contains("Work (Imported)")
        XCTAssertTrue(value2)
    }

    private func snapshotCounts(_ location: LibraryLocation, container existing: NSPersistentContainer? = nil) async throws -> (notes: Int, folders: Int) {
        let container: NSPersistentContainer
        if let existing {
            container = existing
        } else {
            container = try await CoreDataStack.openContainer(at: location)
        }
        defer { if existing == nil { try? CoreDataStack.close(container) } }
        let repository = LibraryRepository(container: container)
        let notes = try await repository.activeNotes(inFolder: nil).count + repository.deletedNotes().count
        return (notes, try await repository.folders().count)
    }

    // MARK: - Refused archives

    private func editManifest(_ archive: URL, mutate: (inout [String: Any]) -> Void) throws {
        let url = archive.appending(path: "manifest.json", directoryHint: .notDirectory)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        mutate(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    func testChangedDocumentIsRefusedBeforeAnythingIsImported() async throws {
        let source = makeLocation("archive-bad-source")
        _ = try await populate(source)
        let archive = try await export(source)
        let document = archive.appending(path: "archive.json", directoryHint: .notDirectory)
        try Data(contentsOf: document).write(to: document, options: .atomic)
        var text = try String(contentsOf: document)
        text = text.replacingOccurrences(of: "Passport", with: "Passpart")
        try text.write(to: document, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ArchiveService.read(at: archive, existingFolderNames: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .checksumMismatch)
        }
    }

    func testUnlistedFileIsRefused() async throws {
        let source = makeLocation("archive-extra-source")
        _ = try await populate(source)
        let archive = try await export(source)
        try Data("extra".utf8).write(to: archive.appending(path: "extra.txt", directoryHint: .notDirectory))

        XCTAssertThrowsError(try ArchiveService.read(at: archive, existingFolderNames: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .unexpectedFile)
        }
    }

    func testMissingFileIsRefused() async throws {
        let source = makeLocation("archive-missing-source")
        _ = try await populate(source)
        let archive = try await export(source)
        try FileManager.default.removeItem(at: archive.appending(path: "archive.json", directoryHint: .notDirectory))

        XCTAssertThrowsError(try ArchiveService.read(at: archive, existingFolderNames: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .missingFile)
        }
    }

    func testUnsupportedVersionIsRefused() async throws {
        let source = makeLocation("archive-version-source")
        _ = try await populate(source)
        let archive = try await export(source)
        try editManifest(archive) { $0["formatVersion"] = 2 }

        XCTAssertThrowsError(try ArchiveService.read(at: archive, existingFolderNames: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .unsupportedVersion(2))
        }
    }

    func testPathTraversalIsRefused() async throws {
        let source = makeLocation("archive-path-source")
        _ = try await populate(source)
        let archive = try await export(source)
        try editManifest(archive) { json in
            var files = json["files"] as! [String: String]
            files["../escape.txt"] = "00"
            json["files"] = files
        }

        XCTAssertThrowsError(try ArchiveService.read(at: archive, existingFolderNames: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .unsafePath)
        }
    }

    func testSymbolicLinkIsRefused() async throws {
        let source = makeLocation("archive-link-source")
        _ = try await populate(source)
        let archive = try await export(source)
        let target = archive.appending(path: "archive.json", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: archive.appending(path: "link.json", directoryHint: .notDirectory), withDestinationURL: target)

        XCTAssertThrowsError(try ArchiveService.read(at: archive, existingFolderNames: [])) { error in
            XCTAssertEqual(error as? ArchiveError, .unsafePath)
        }
    }

    func testAFailedImportWritesNothingAndRemovesItsBytes() async throws {
        let source = makeLocation("archive-fail-source")
        _ = try await populate(source)
        let archive = try await export(source)

        let target = makeLocation("archive-fail-target")
        let container = try await CoreDataStack.openContainer(at: target)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let validated = try ArchiveService.read(at: archive, existingFolderNames: [])
        let failing = FailingImportStore(base: repository)

        do {
            _ = try await ArchiveService.importArchive(validated, location: target, store: failing)
            XCTFail("The injected failure must fail the import.")
        } catch LibraryError.saveFailed {
        }

        let value3 = try await repository.activeNotes(inFolder: nil).count
        XCTAssertEqual(value3, 0, "No partial import is visible.")
        let value4 = try await repository.folders().map(\.name)
        XCTAssertEqual(value4, ["Notes"])
        let payloads = (try? FileManager.default.contentsOfDirectory(atPath: AttachmentService.attachmentsDirectory(in: target).path)) ?? []
        XCTAssertTrue(payloads.isEmpty, "Copied bytes are removed with the failed transaction.")
    }

    // MARK: - Text and RTF

    func testPlainTextExportAndImportKeepTheText() throws {
        let data = ArchiveService.plainTextExport(title: "Plan", body: "Línea uno\n日本語 🧪")
        let url = makeFolder("text").appending(path: "Plan.txt", directoryHint: .notDirectory)
        try data.write(to: url)

        let imported = try ArchiveService.importPlainText(at: url)

        XCTAssertEqual(imported.title, "Plan")
        XCTAssertEqual(imported.body, "Plan\n\nLínea uno\n日本語 🧪")
    }

    func testRichNoteExportsToRTFAndImportsWithFormattingAndTextIntact() throws {
        let text = NSMutableAttributedString(string: "Bold word here")
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 4))
        let content = try RichTextCodec.content(from: text, checklist: nil)
        let data = try ArchiveService.rtfExport(title: "Rich", body: .rich(content))
        let url = makeFolder("rtf").appending(path: "Rich.rtf", directoryHint: .notDirectory)
        try data.write(to: url)

        let imported = try ArchiveService.importRTF(at: url)

        XCTAssertEqual(imported.title, "Rich")
        XCTAssertTrue(imported.content.plainText.hasSuffix("Bold word here"))
        let decoded = try RichTextCodec.attributedString(of: imported.content)
        let range = (decoded.string as NSString).range(of: "Bold")
        let font = decoded.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font ?? .systemFont(ofSize: 13)).contains(.boldFontMask))
    }

    func testBinaryFileIsNotImportedAsText() throws {
        let url = makeFolder("binary").appending(path: "image.txt", directoryHint: .notDirectory)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)

        XCTAssertThrowsError(try ArchiveService.importPlainText(at: url)) { error in
            XCTAssertEqual(error as? ArchiveError, .notReadableText)
        }
    }

    func testExportRefusesAnExistingDestination() async throws {
        let source = makeLocation("archive-exists")
        _ = try await populate(source)
        let container = try await CoreDataStack.openContainer(at: source)
        defer { try? CoreDataStack.close(container) }
        let existing = makeFolder("taken")

        do {
            _ = try await ArchiveService.export(to: existing, store: LibraryRepository(container: container), location: source)
            XCTFail("An existing folder must not be overwritten.")
        } catch ArchiveError.destinationExists {
        }
    }
}

/// Lets every step run, then fails the archive transaction, so the test can see what was left behind.
actor FailingImportStore: NoteStore {
    private let base: LibraryRepository

    init(base: LibraryRepository) {
        self.base = base
    }

    func importArchive(_ plan: ArchiveImportPlan) async throws {
        throw LibraryError.saveFailed("Injected transaction failure.")
    }

    func initializeLibraryIfNeeded() async throws -> LibraryMetadataSnapshot { try await base.initializeLibraryIfNeeded() }
    func folders() async throws -> [FolderSnapshot] { try await base.folders() }
    func activeNotes(inFolder folderID: UUID?) async throws -> [NoteSnapshot] { try await base.activeNotes(inFolder: folderID) }
    func createNote(inFolder folderID: UUID, title: String, bodyPlainText: String) async throws -> NoteSnapshot { try await base.createNote(inFolder: folderID, title: title, bodyPlainText: bodyPlainText) }
    func updateNote(id: UUID, expectedRevision: Int64, title: String, bodyPlainText: String) async throws -> NoteSnapshot { try await base.updateNote(id: id, expectedRevision: expectedRevision, title: title, bodyPlainText: bodyPlainText) }
    func body(of id: UUID) async throws -> NoteBody { try await base.body(of: id) }
    func updateRichNote(id: UUID, expectedRevision: Int64, title: String, content: RichNoteContent) async throws -> NoteSnapshot { try await base.updateRichNote(id: id, expectedRevision: expectedRevision, title: title, content: content) }
    func makeRecoveryCopy(of id: UUID) async throws -> NoteSnapshot { try await base.makeRecoveryCopy(of: id) }
    func searchActiveNotes(matching query: String) async throws -> [NoteSnapshot] { try await base.searchActiveNotes(matching: query) }
    func trashNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot { try await base.trashNote(id: id, expectedRevision: expectedRevision) }
    func restoreNote(id: UUID, expectedRevision: Int64) async throws -> NoteSnapshot { try await base.restoreNote(id: id, expectedRevision: expectedRevision) }
    func deletedNotes() async throws -> [NoteSnapshot] { try await base.deletedNotes() }
    func deleteFolder(id: UUID) async throws { try await base.deleteFolder(id: id) }
    func permanentlyDeleteNote(id: UUID, expectedRevision: Int64) async throws { try await base.permanentlyDeleteNote(id: id, expectedRevision: expectedRevision) }
    func setNotePinned(id: UUID, expectedRevision: Int64, isPinned: Bool) async throws -> NoteSnapshot { try await base.setNotePinned(id: id, expectedRevision: expectedRevision, isPinned: isPinned) }
    func createFolder(named name: String) async throws -> FolderSnapshot { try await base.createFolder(named: name) }
    func renameFolder(id: UUID, to name: String) async throws -> FolderSnapshot { try await base.renameFolder(id: id, to: name) }
    func moveNote(id: UUID, expectedRevision: Int64, toFolderID folderID: UUID) async throws -> NoteSnapshot { try await base.moveNote(id: id, expectedRevision: expectedRevision, toFolderID: folderID) }
    func createAttachment(_ new: NewAttachment) async throws -> AttachmentSnapshot { try await base.createAttachment(new) }
    func deleteAttachment(id: UUID) async throws { try await base.deleteAttachment(id: id) }
    func attachments(forNote noteID: UUID) async throws -> [AttachmentSnapshot] { try await base.attachments(forNote: noteID) }
    func allAttachments() async throws -> [AttachmentSnapshot] { try await base.allAttachments() }
}
