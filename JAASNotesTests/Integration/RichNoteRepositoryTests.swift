import AppKit
import CoreData
import XCTest
@testable import JAASNotes

/// Rich bodies in the store: saves, revision checks, reopen, unreadable originals, and recovery copies (03-01).
@MainActor
final class RichNoteRepositoryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func makeLocation() -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-rich-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(root)
        return LibraryLocation(rootURL: root)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func openRepository(_ location: LibraryLocation, clock: Date? = nil) async throws -> (LibraryRepository, NSPersistentContainer) {
        let container = try await CoreDataStack.openContainer(at: location)
        let date = clock ?? fixedDate
        let repository = LibraryRepository(container: container, now: { date })
        _ = try await repository.initializeLibraryIfNeeded()
        return (repository, container)
    }

    /// Formatted text with a bold word, an italic word, and a checklist on the first paragraph.
    private func sampleContent(checklistItem: ChecklistItem? = nil) throws -> RichNoteContent {
        let text = NSMutableAttributedString(string: "Shopping list 🛒\nMilk 日本語\nLast line")
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 8))
        let checklist = checklistItem.map { ChecklistSidecar(items: [$0]) }
        return try RichTextCodec.content(from: text, checklist: checklist)
    }

    // MARK: - Saving rich text

    func testPlainNoteBecomesRichOnFirstRichSaveAndSurvivesReopen() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Shopping", bodyPlainText: "Old text")
        XCTAssertFalse(plain.hasRichContent)
        let value1 = try await repository.body(of: plain.id)
        XCTAssertEqual(value1, .plain("Old text"), "Plain notes are not converted when they open.")

        let itemID = UUID()
        let content = try sampleContent(checklistItem: ChecklistItem(id: itemID, isChecked: true, location: 17, length: 8))
        let saved = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Shopping", content: content)

        XCTAssertTrue(saved.hasRichContent)
        XCTAssertEqual(saved.revision, plain.revision + 1)
        XCTAssertEqual(saved.bodyPlainText, content.plainText, "The search text is derived from the rich body.")
        try CoreDataStack.close(container)

        let (reopened, reopenedContainer) = try await openRepository(location)
        defer { try? CoreDataStack.close(reopenedContainer) }
        let reread = try await reopened.body(of: plain.id)
        guard case .rich(let restored) = reread else {
            return XCTFail("Expected a rich body after reopen, got \(reread)")
        }
        XCTAssertEqual(restored.plainText, content.plainText)
        XCTAssertEqual(restored.rtf, content.rtf)
        XCTAssertEqual(restored.checklist?.items.first?.id, itemID)
        XCTAssertEqual(restored.checklist?.items.first?.isChecked, true)
    }

    func testIdenticalRichSaveIsNotAChange() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        defer { try? CoreDataStack.close(container) }
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Same", bodyPlainText: "")
        let content = try sampleContent()
        let first = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Same", content: content)

        let second = try await repository.updateRichNote(id: plain.id, expectedRevision: first.revision, title: "Same", content: content)

        XCTAssertEqual(second.revision, first.revision, "Saving the same formatting does not create a revision.")
        XCTAssertEqual(second.modifiedAt, first.modifiedAt)
    }

    func testStaleRichSaveIsRejectedAndChangesNothing() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        defer { try? CoreDataStack.close(container) }
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Stale", bodyPlainText: "")
        let first = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Stale", content: try sampleContent())
        let before = try await repository.body(of: plain.id)

        do {
            _ = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Stale", content: try RichTextCodec.content(from: NSAttributedString(string: "Overwrite"), checklist: nil))
            XCTFail("A save against an old revision must be refused.")
        } catch LibraryError.revisionConflict(let id) {
            XCTAssertEqual(id, plain.id)
        }

        let value2 = try await repository.body(of: plain.id)
        XCTAssertEqual(value2, before)
        let value3 = try await repository.activeNotes(inFolder: folderID).first { $0.id == plain.id }?.revision
        XCTAssertEqual(value3, first.revision)
    }

    func testPlainTextSaveCannotDiscardFormatting() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        defer { try? CoreDataStack.close(container) }
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Rich", bodyPlainText: "")
        let rich = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Rich", content: try sampleContent())
        let before = try await repository.body(of: plain.id)

        do {
            _ = try await repository.updateNote(id: plain.id, expectedRevision: rich.revision, title: "Rich", bodyPlainText: "Flattened")
            XCTFail("Plain text must not replace formatted text.")
        } catch LibraryError.richContentRequiresRichUpdate(let id) {
            XCTAssertEqual(id, plain.id)
        }

        let value4 = try await repository.body(of: plain.id)
        XCTAssertEqual(value4, before, "The formatting is still there.")
    }

    func testRichTextIsSearchableByVisibleTextOnly() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        defer { try? CoreDataStack.close(container) }
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Search", bodyPlainText: "")
        _ = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Search", content: try sampleContent())

        let value5 = try await repository.searchActiveNotes(matching: "MILK 日本").map(\.id)
        XCTAssertEqual(value5, [plain.id])
        let value6 = try await repository.searchActiveNotes(matching: "rtf1").map(\.id)
        XCTAssertEqual(value6, [], "RTF control words are not searchable text.")
    }

    // MARK: - Unreadable originals

    /// Replaces the stored formatting bytes behind the repository's back, the way a damaged file would.
    private func corruptStoredFormatting(of id: UUID, in container: NSPersistentContainer, rtf: Data?, checklist: Data? = nil, format: Int32? = nil) throws {
        let context = container.newBackgroundContext()
        try context.performAndWait {
            let request = NSFetchRequest<NoteRecord>(entityName: "Note")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            let note = try XCTUnwrap(try context.fetch(request).first)
            note.richTextData = rtf
            note.checklistData = checklist
            if let format {
                note.contentFormatVersion = format
            }
            try context.save()
        }
    }

    private func storedFormatting(of id: UUID, in container: NSPersistentContainer) throws -> (rtf: Data?, checklist: Data?, format: Int32) {
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<NoteRecord>(entityName: "Note")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            let note = try XCTUnwrap(try context.fetch(request).first)
            return (note.richTextData, note.checklistData, note.contentFormatVersion)
        }
    }

    func testDamagedFormattingIsReportedWithTheSavedTextAndNeverOverwritten() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Damaged", bodyPlainText: "")
        let good = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Damaged", content: try sampleContent())
        try corruptStoredFormatting(of: plain.id, in: container, rtf: Data("garbage".utf8))
        try CoreDataStack.close(container)

        let (reopened, reopenedContainer) = try await openRepository(location)
        defer { try? CoreDataStack.close(reopenedContainer) }
        let damaged = try await reopened.body(of: plain.id)
        guard case .unreadable(let fallback, let reason) = damaged else {
            return XCTFail("Expected an unreadable body, got \(damaged)")
        }
        XCTAssertEqual(fallback, good.bodyPlainText, "The last saved text is the fallback.")
        XCTAssertFalse(reason.isEmpty)
        let bytesBefore = try storedFormatting(of: plain.id, in: reopenedContainer)

        do {
            _ = try await reopened.updateRichNote(id: plain.id, expectedRevision: good.revision, title: "Replaced", content: try sampleContent())
            XCTFail("An unreadable original must not be overwritten.")
        } catch LibraryError.richContentUnreadable(let id) {
            XCTAssertEqual(id, plain.id)
        }
        do {
            _ = try await reopened.updateNote(id: plain.id, expectedRevision: good.revision, title: "Replaced", bodyPlainText: "Replaced")
            XCTFail("A plain save must not replace an unreadable original either.")
        } catch LibraryError.richContentRequiresRichUpdate {
        }

        let bytesAfter = try storedFormatting(of: plain.id, in: reopenedContainer)
        XCTAssertEqual(bytesAfter.rtf, bytesBefore.rtf, "The damaged bytes are byte-identical.")
        XCTAssertEqual(bytesAfter.format, bytesBefore.format)
    }

    func testMissingChecklistForRichNoteIsUnreadable() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Bad checklist", bodyPlainText: "")
        _ = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Bad checklist", content: try sampleContent())
        try corruptStoredFormatting(of: plain.id, in: container, rtf: try sampleContent().rtf, checklist: Data("{broken".utf8))
        try CoreDataStack.close(container)

        let (reopened, reopenedContainer) = try await openRepository(location)
        defer { try? CoreDataStack.close(reopenedContainer) }
        let body = try await reopened.body(of: plain.id)

        guard case .unreadable = body else {
            return XCTFail("A damaged checklist must make the note unreadable, got \(body)")
        }
        try CoreDataStack.close(container)
    }

    func testFormatFromANewerVersionIsUnreadableAndUnchanged() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Future", bodyPlainText: "Kept text")
        try corruptStoredFormatting(of: plain.id, in: container, rtf: Data("future".utf8), format: 9)
        try CoreDataStack.close(container)

        let (reopened, reopenedContainer) = try await openRepository(location)
        defer { try? CoreDataStack.close(reopenedContainer) }
        let body = try await reopened.body(of: plain.id)

        guard case .unreadable(let fallback, _) = body else {
            return XCTFail("Expected an unreadable body, got \(body)")
        }
        XCTAssertEqual(fallback, "Kept text")
        XCTAssertEqual(try storedFormatting(of: plain.id, in: reopenedContainer).format, 9)
    }

    func testRecoveryCopyKeepsTheTextAndLeavesTheOriginalAlone() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Keep me", bodyPlainText: "")
        let good = try await repository.updateRichNote(id: plain.id, expectedRevision: plain.revision, title: "Keep me", content: try sampleContent())
        try corruptStoredFormatting(of: plain.id, in: container, rtf: Data("garbage".utf8))
        let originalBytes = try storedFormatting(of: plain.id, in: container)
        try CoreDataStack.close(container)

        let (reopened, reopenedContainer) = try await openRepository(location)
        defer { try? CoreDataStack.close(reopenedContainer) }
        let copy = try await reopened.makeRecoveryCopy(of: plain.id)

        XCTAssertEqual(copy.folderID, folderID)
        XCTAssertEqual(copy.title, "Keep me (Recovered)")
        XCTAssertEqual(copy.bodyPlainText, good.bodyPlainText)
        XCTAssertFalse(copy.hasRichContent)
        XCTAssertNotEqual(copy.id, plain.id)
        XCTAssertEqual(try storedFormatting(of: plain.id, in: reopenedContainer).rtf, originalBytes.rtf)
        let activeCount = try await reopened.activeNotes(inFolder: folderID).count
        XCTAssertEqual(activeCount, 2)
    }

    func testRecoveryCopyIsRefusedForANoteThatOpensNormally() async throws {
        let location = makeLocation()
        let (repository, container) = try await openRepository(location)
        defer { try? CoreDataStack.close(container) }
        let folderID = try await repository.folders()[0].id
        let plain = try await repository.createNote(inFolder: folderID, title: "Fine", bodyPlainText: "Fine")

        do {
            _ = try await repository.makeRecoveryCopy(of: plain.id)
            XCTFail("A readable note does not need a recovery copy.")
        } catch LibraryError.recoveryCopyNotNeeded(let id) {
            XCTAssertEqual(id, plain.id)
        }
    }
}
