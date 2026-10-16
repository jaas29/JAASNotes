import CoreData
import XCTest
@testable import JAASNotes

/// Save behavior against real SQLite stores, with store failures and pauses injected in a fixed order.
@MainActor
final class AutosaveTests: XCTestCase {
    func testFlushPersistsEditsAcrossReopen() async throws {
        let location = SaveFixture.makeLocation(in: self)
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        let model = LibraryModel(sleep: SaveFixture.holdSleep)
        await model.load(store: repository)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)

        model.updateDraft(for: noteID, title: "Café 🧪", body: "Línea uno\n日本語")
        let saved = await model.flushPendingDrafts()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.saveStatus(for: noteID), .saved)
        try CoreDataStack.close(container)

        let reopened = try await CoreDataStack.openContainer(at: location)
        let notes = try await LibraryRepository(container: reopened).activeNotes(inFolder: nil)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Café 🧪")
        XCTAssertEqual(notes.first?.bodyPlainText, "Línea uno\n日本語")
        XCTAssertEqual(notes.first?.revision, 2)
        try CoreDataStack.close(reopened)
    }

    func testFailedSaveKeepsDraftAndReportsFailure() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        await fixture.faulty.failNextUpdates(1)

        model.updateDraft(for: fixture.noteID, title: "Draft title", body: "Draft body")
        let saved = await model.flushPendingDrafts()

        XCTAssertFalse(saved)
        guard case .failed = model.saveStatus(for: fixture.noteID) else {
            return XCTFail("Expected a failed status, got \(model.saveStatus(for: fixture.noteID))")
        }
        XCTAssertNotNil(model.saveFailure)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.notes.first { $0.id == fixture.noteID }.map { model.draft(for: $0).title }, "Draft title")

        let stored = try await fixture.base.activeNotes(inFolder: nil)
        XCTAssertEqual(stored.first?.title, "", "A failed write must not change the stored note.")
    }

    func testRetryAfterFailureSavesWithoutDuplicatingNotes() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        await fixture.faulty.failNextUpdates(1)
        model.updateDraft(for: fixture.noteID, title: "Draft title", body: "Draft body")
        let firstAttempt = await model.flushPendingDrafts()
        XCTAssertFalse(firstAttempt)

        let retried = await model.retrySave()

        XCTAssertTrue(retried)
        XCTAssertEqual(model.saveStatus(for: fixture.noteID), .saved)
        XCTAssertNil(model.saveFailure)
        XCTAssertFalse(model.hasUnsavedChanges)
        let stored = try await fixture.base.activeNotes(inFolder: nil)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.title, "Draft title")
        XCTAssertEqual(stored.first?.bodyPlainText, "Draft body")
    }

    func testSaveThatFinishesAfterNewerEditLeavesNewerTextDirty() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let noteID = fixture.noteID

        await fixture.faulty.pauseNextUpdate()
        model.updateDraft(for: noteID, body: "one")
        let firstFlush = Task { await model.flushPendingDrafts() }
        await fixture.faulty.waitUntilUpdateIsPaused()

        // A newer edit arrives while the save of "one" is in flight. Hold the follow-up save too.
        model.updateDraft(for: noteID, body: "two")
        await fixture.faulty.pauseNextUpdate()
        await fixture.faulty.resumeUpdate()
        await fixture.faulty.waitUntilUpdateIsPaused()

        XCTAssertTrue(model.isDirty(noteID), "The older save must not mark newer text as saved.")
        XCTAssertNotEqual(model.saveStatus(for: noteID), .saved)

        await fixture.faulty.resumeUpdate()
        let saved = await firstFlush.value
        XCTAssertTrue(saved)
        XCTAssertFalse(model.isDirty(noteID))
        let stored = try await fixture.base.activeNotes(inFolder: nil)
        XCTAssertEqual(stored.first?.bodyPlainText, "two")
    }

    func testChangingNotesIsBlockedWhileSaveFails() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let firstID = fixture.noteID
        await model.createNote()
        let secondID = try XCTUnwrap(model.selectedNoteID)
        await model.requestNoteSelection(firstID)

        model.updateDraft(for: firstID, title: "Unsaved")
        await fixture.faulty.failNextUpdates(1)
        await model.requestNoteSelection(secondID)

        XCTAssertEqual(model.selectedNoteID, firstID, "Selection must not move while the draft is unsaved.")
        XCTAssertNotNil(model.saveFailure)

        let retried = await model.retrySave()
        XCTAssertTrue(retried)
        await model.requestNoteSelection(secondID)
        XCTAssertEqual(model.selectedNoteID, secondID)
    }

    func testCreatingNoteIsRefusedWhileSaveFails() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Unsaved")
        await fixture.faulty.failNextUpdates(1)

        await model.createNote()

        XCTAssertEqual(model.notes.count, 1, "A new note must not be created over an unsaved failure.")
        XCTAssertNotNil(model.saveFailure)
    }

    func testRecoveryCopyContainsUnsavedTextAndIsVerified() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Unsaved title", body: "Unsaved body")
        await fixture.faulty.failNextUpdates(1)
        let saved = await model.flushPendingDrafts()
        XCTAssertFalse(saved)

        let url = FileManager.default.temporaryDirectory.appending(path: "recovery-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(model.saveRecoveryCopy(to: url))
        let drafts = try RecoveryCopy.read(from: url)
        XCTAssertEqual(drafts.map(\.noteID), [fixture.noteID])
        XCTAssertEqual(drafts.first?.title, "Unsaved title")
        XCTAssertEqual(drafts.first?.bodyPlainText, "Unsaved body")
        XCTAssertEqual(drafts.first?.savedRevision, 1)
    }

    func testRecoveryCopyFailureIsReportedAndDraftsRemain() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Unsaved")
        await fixture.faulty.failNextUpdates(1)
        _ = await model.flushPendingDrafts()

        let missingFolder = FileManager.default.temporaryDirectory
            .appending(path: "missing-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "recovery.json")

        XCTAssertFalse(model.saveRecoveryCopy(to: missingFolder))
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(model.hasUnsavedChanges, "A failed recovery copy must not clear the draft.")
    }

    func testDiscardReturnsNoteToStoredText() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Unwanted")
        await fixture.faulty.failNextUpdates(1)
        _ = await model.flushPendingDrafts()

        model.discardUnsavedChanges()

        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.saveFailure)
        XCTAssertEqual(model.saveStatus(for: fixture.noteID), .saved)
        let stored = try await fixture.base.activeNotes(inFolder: nil)
        XCTAssertEqual(stored.first?.title, "")
    }
}
