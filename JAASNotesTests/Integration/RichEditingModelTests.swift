import AppKit
import CoreData
import XCTest
@testable import JAASNotes

/// Formatted editing through the app model: saves, reopen, failed saves, damaged formatting, and recovery copies (03-02).
@MainActor
final class RichEditingModelTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func makeLocation() -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-richmodel-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(root)
        return LibraryLocation(rootURL: root)
    }

    /// Bold "Shopping" in the first line, with a plain second line.
    private func formattedText(_ string: String = "Shopping\nMilk") -> NSAttributedString {
        let text = NSMutableAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 8))
        return text
    }

    private func isBold(_ text: NSAttributedString, at index: Int) -> Bool {
        let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    func testFormattingAPlainNoteSavesRichAndSurvivesReopen() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        let model = LibraryModel(sleep: SaveFixture.holdSleep)
        await model.load(store: repository)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: noteID, title: "Shopping", body: "Shopping\nMilk")

        model.updateRichDraft(for: noteID, text: formattedText(), checklist: nil)
        let flushed = await model.flushPendingDrafts()
        XCTAssertTrue(flushed)
        XCTAssertTrue(try XCTUnwrap(model.notes.first { $0.id == noteID }).hasRichContent)
        try CoreDataStack.close(container)

        let reopened = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(reopened) }
        let reopenedModel = LibraryModel(sleep: SaveFixture.holdSleep)
        await reopenedModel.load(store: LibraryRepository(container: reopened))
        let note = try XCTUnwrap(reopenedModel.notes.first { $0.id == noteID })
        XCTAssertEqual(reopenedModel.bodyState(for: note), .loading, "A formatted note loads its body before it is shown.")

        await reopenedModel.prepareBody(for: note)

        XCTAssertEqual(reopenedModel.bodyState(for: note), .ready)
        let draft = reopenedModel.draft(for: note)
        XCTAssertEqual(draft.bodyPlainText, "Shopping\nMilk")
        let rich = try XCTUnwrap(draft.rich?.text)
        XCTAssertTrue(isBold(rich, at: 2))
        XCTAssertFalse(isBold(rich, at: 12))
    }

    func testFailedRichSaveKeepsTheFormattingAndRetrySaves() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let faulty = FaultyNoteStore(base: LibraryRepository(container: container))
        let model = LibraryModel(sleep: SaveFixture.holdSleep)
        await model.load(store: faulty)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)

        await faulty.failNextUpdates(1)
        model.updateRichDraft(for: noteID, text: formattedText(), checklist: nil)
        let firstAttempt = await model.flushPendingDrafts()

        XCTAssertFalse(firstAttempt)
        XCTAssertNotNil(model.drafts[noteID]?.rich, "The formatted draft stays in memory after a failed save.")
        if case .failed = model.saveStatus(for: noteID) {
        } else {
            XCTFail("A failed formatted save must be reported, not shown as saved.")
        }

        let retried = await model.retrySave()
        XCTAssertTrue(retried)
        XCTAssertEqual(model.saveStatus(for: noteID), .saved)
        XCTAssertTrue(try XCTUnwrap(model.notes.first { $0.id == noteID }).hasRichContent)
    }

    /// Stores formatting, then replaces its bytes behind the repository's back, the way a damaged file would.
    private func storeDamagedFormatting(_ location: LibraryLocation) async throws -> UUID {
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        let note = try await repository.createNote(inFolder: folderID, title: "Damaged", bodyPlainText: "")
        let content = try RichTextCodec.content(from: formattedText(), checklist: nil)
        _ = try await repository.updateRichNote(id: note.id, expectedRevision: note.revision, title: "Damaged", content: content)
        try CoreDataStack.close(container)

        let writer = try await CoreDataStack.openContainer(at: location)
        let context = writer.newBackgroundContext()
        try context.performAndWait {
            let request = NSFetchRequest<NoteRecord>(entityName: "Note")
            request.predicate = NSPredicate(format: "id == %@", note.id as NSUUID)
            let record = try XCTUnwrap(try context.fetch(request).first)
            record.richTextData = Data("garbage".utf8)
            try context.save()
        }
        try CoreDataStack.close(writer)
        return note.id
    }

    func testDamagedFormattingIsReadOnlyAndRecoveryCopyKeepsTheText() async throws {
        let location = makeLocation()
        let noteID = try await storeDamagedFormatting(location)

        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let model = LibraryModel(sleep: SaveFixture.holdSleep)
        await model.load(store: LibraryRepository(container: container))
        let note = try XCTUnwrap(model.notes.first { $0.id == noteID })

        await model.prepareBody(for: note)

        guard case .unreadable(let fallback, let reason) = model.bodyState(for: note) else {
            return XCTFail("Damaged formatting must be reported, got \(model.bodyState(for: note))")
        }
        XCTAssertEqual(fallback, "Shopping\nMilk", "The saved text is still shown.")
        XCTAssertFalse(reason.isEmpty)

        model.updateDraft(for: noteID, body: "Overwritten")
        model.updateRichDraft(for: noteID, text: formattedText("Overwritten"), checklist: nil)
        XCTAssertNil(model.drafts[noteID], "A damaged note takes no edits.")
        XCTAssertFalse(model.hasUnsavedChanges)

        let created = await model.makeRecoveryCopy(for: noteID)

        XCTAssertTrue(created)
        let copy = try XCTUnwrap(model.notes.first { $0.id == model.selectedNoteID })
        XCTAssertEqual(copy.title, "Damaged (Recovered)")
        XCTAssertEqual(copy.bodyPlainText, "Shopping\nMilk")
        XCTAssertFalse(copy.hasRichContent)
        XCTAssertEqual(model.bodyState(for: copy), .ready)
    }

    /// Checklist items keep their identity and checked state through a save and a restart, with emoji and Japanese text.
    func testChecklistIdentityAndStateSurviveRestart() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        let model = LibraryModel(sleep: SaveFixture.holdSleep)
        await model.load(store: LibraryRepository(container: container))
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)

        // "買い物 🛒" is 6 UTF-16 units, "Eggs 🥚" is 7, and "日本語のメモ" is 6.
        let text = NSAttributedString(string: "買い物 🛒\nEggs 🥚\n日本語のメモ")
        let checked = ChecklistItem(id: UUID(), isChecked: true, location: 0, length: 6)
        let open = ChecklistItem(id: UUID(), isChecked: false, location: 7, length: 7)
        let kanji = ChecklistItem(id: UUID(), isChecked: true, location: 15, length: 6)
        let checklist = ChecklistSidecar(items: [checked, open, kanji])
        model.updateRichDraft(for: noteID, text: text, checklist: checklist)
        let flushed = await model.flushPendingDrafts()
        XCTAssertTrue(flushed)
        try CoreDataStack.close(container)

        let reopened = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(reopened) }
        let reopenedModel = LibraryModel(sleep: SaveFixture.holdSleep)
        await reopenedModel.load(store: LibraryRepository(container: reopened))
        let note = try XCTUnwrap(reopenedModel.notes.first { $0.id == noteID })
        await reopenedModel.prepareBody(for: note)

        let restored = try XCTUnwrap(reopenedModel.draft(for: note).rich?.checklist)
        XCTAssertEqual(restored.items.map(\.id), [checked.id, open.id, kanji.id])
        XCTAssertEqual(restored.items.map(\.isChecked), [true, false, true])
        XCTAssertEqual(restored.items.map(\.location), [0, 7, 15])
    }
}
