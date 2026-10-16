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

/// Folder and move commands at the model level: pending text is saved first, and failures change nothing.
@MainActor
final class FolderModelTests: XCTestCase {
    private func defaultFolderID(_ model: LibraryModel) throws -> UUID {
        try XCTUnwrap(model.folders.first { $0.isDefault }?.id)
    }

    func testCreatedFolderIsSelected() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let folder = try await fixture.model.createFolder(named: "Work")
        XCTAssertEqual(fixture.model.sidebarSelection, .folder(folder.id))
        XCTAssertEqual(fixture.model.folders.map(\.name), ["Notes", "Work"])
    }

    func testFailedFolderCreationShowsErrorAndCreatesNothing() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        await fixture.faulty.failNextStructuralWrites(1)

        do {
            _ = try await fixture.model.createFolder(named: "Work")
            XCTFail("The injected failure must be thrown to the sheet.")
        } catch {
        }
        XCTAssertEqual(fixture.model.folders.map(\.name), ["Notes"])
    }

    func testRenameRejectionKeepsTheExistingName() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let work = try await fixture.model.createFolder(named: "Work")
        do {
            try await fixture.model.renameFolder(work.id, to: "notes")
            XCTFail("A name that duplicates the default folder must be rejected.")
        } catch LibraryError.duplicateFolderName {
        }
        XCTAssertEqual(fixture.model.folders.first { $0.id == work.id }?.name, "Work")
    }

    func testMoveSavesPendingTextFirst() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let work = try await model.createFolder(named: "Work")
        model.updateDraft(for: fixture.noteID, title: "Moved with text", body: "Body")

        let moved = await model.moveNote(fixture.noteID, toFolder: work.id)

        XCTAssertTrue(moved)
        XCTAssertFalse(model.hasUnsavedChanges)
        let stored = try await fixture.base.activeNotes(inFolder: work.id)
        XCTAssertEqual(stored.first?.title, "Moved with text")
        XCTAssertEqual(stored.first?.bodyPlainText, "Body")
    }

    func testMoveIsRefusedWhileSaveFailsAndNoteStaysPut() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let work = try await model.createFolder(named: "Work")
        await fixture.faulty.failNextUpdates(1)
        model.updateDraft(for: fixture.noteID, title: "Still draft")

        let moved = await model.moveNote(fixture.noteID, toFolder: work.id)

        XCTAssertFalse(moved)
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(model.hasUnsavedChanges, "The draft must survive a refused move.")
        let defaultID = try defaultFolderID(model)
        let stored = try await fixture.base.activeNotes(inFolder: defaultID)
        XCTAssertEqual(stored.map(\.id), [fixture.noteID])
    }

    func testFailedMoveWriteLeavesNoteAndSelectionUnchanged() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let work = try await model.createFolder(named: "Work")
        let defaultID = try defaultFolderID(model)
        await model.requestSidebarSelection(.folder(defaultID))
        await model.requestNoteSelection(fixture.noteID)
        await fixture.faulty.failNextStructuralWrites(1)

        let moved = await model.moveNote(fixture.noteID, toFolder: work.id)

        XCTAssertFalse(moved)
        XCTAssertEqual(model.selectedNoteID, fixture.noteID)
        XCTAssertEqual(model.notes.first { $0.id == fixture.noteID }?.folderID, defaultID)
    }

    func testSelectionClearsWhenNoteMovesOutOfTheShownFolder() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let work = try await model.createFolder(named: "Work")
        let defaultID = try defaultFolderID(model)
        await model.requestSidebarSelection(.folder(defaultID))
        await model.requestNoteSelection(fixture.noteID)
        XCTAssertEqual(model.selectedNoteID, fixture.noteID)

        let moved = await model.moveNote(fixture.noteID, toFolder: work.id)

        XCTAssertTrue(moved)
        XCTAssertNil(model.selectedNoteID, "The editor must not keep showing a note that left the folder.")
    }

    func testSelectionChangeAppliesNewestFirstOrder() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        await model.createNote()
        let newest = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: fixture.noteID, title: "Edited older note")
        await model.flushPendingDrafts()

        await model.requestNoteSelection(fixture.noteID)

        XCTAssertEqual(model.notes.first?.id, fixture.noteID, "The edited note is now the newest.")
        XCTAssertNotEqual(newest, fixture.noteID)
    }
}

/// Search state at the model level: debounce, stale-result protection, scope, and the draft overlay.
@MainActor
final class SearchModelTests: XCTestCase {
    /// Stored and unsaved text, the stored-only case, and folder scope.
    func testStoredMatchesAreListedAndClearingRestoresTheList() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "Needle in title")
        await model.flushPendingDrafts()

        model.setSearchText("needle")
        await model.pendingSearch?.value
        XCTAssertEqual(model.listedNotes.map(\.id), [fixture.noteID])

        model.clearSearch()
        XCTAssertEqual(model.listedNotes.map(\.id), model.visibleNotes.map(\.id))
        XCTAssertFalse(model.isSearching)
    }

    func testUnsavedDraftMatchesBeforeAnySave() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, body: "typed but not saved needle")

        model.setSearchText("needle")
        await model.pendingSearch?.value

        XCTAssertEqual(model.listedNotes.map(\.id), [fixture.noteID], "Pending text must be searchable.")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testDatabaseMatchDoesNotHideUnsavedEditThatRemovedTheWord() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "needle")
        await model.flushPendingDrafts()
        model.setSearchText("needle")
        await model.pendingSearch?.value

        // The stored note still matches, and the unsaved draft no longer does. The note must stay listed with its draft.
        model.updateDraft(for: fixture.noteID, title: "removed")
        XCTAssertEqual(model.listedNotes.map(\.id), [fixture.noteID])
        XCTAssertEqual(model.draft(for: try XCTUnwrap(model.notes.first)).title, "removed")
    }

    func testOlderSearchFinishingLateCannotReplaceNewerResults() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "abc")
        await model.flushPendingDrafts()
        await model.createNote()
        let secondID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: secondID, title: "ab")
        await model.flushPendingDrafts()

        // "ab" matches both notes. Hold that query, then search "abc", which matches only the first note.
        await fixture.faulty.holdSearch(for: "ab")
        model.setSearchText("ab")
        let slowSearch = model.pendingSearch
        await fixture.faulty.waitUntilSearchIsHeld(for: "ab")

        model.setSearchText("abc")
        await model.pendingSearch?.value
        XCTAssertEqual(model.listedNotes.map(\.id), [fixture.noteID])

        await fixture.faulty.releaseSearch(for: "ab")
        await slowSearch?.value
        XCTAssertEqual(model.listedNotes.map(\.id), [fixture.noteID],
                       "The late result for the older query must not replace the newer one.")
    }

    func testCurrentFolderScopeLimitsResultsToTheSelectedFolder() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let work = try await model.createFolder(named: "Work")
        await model.createNote()
        let workNoteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: workNoteID, title: "needle in work")
        await model.flushPendingDrafts()

        await model.requestSidebarSelection(.allNotes)
        await model.requestNoteSelection(fixture.noteID)
        model.updateDraft(for: fixture.noteID, title: "needle at home")
        await model.flushPendingDrafts()

        model.setSearchText("needle")
        await model.pendingSearch?.value
        XCTAssertEqual(Set(model.listedNotes.map(\.id)), [workNoteID, fixture.noteID])

        await model.requestSidebarSelection(.folder(work.id))
        model.searchScope = .currentFolder
        XCTAssertEqual(model.listedNotes.map(\.id), [workNoteID])

        model.searchScope = .allNotes
        XCTAssertEqual(Set(model.listedNotes.map(\.id)), [workNoteID, fixture.noteID])
    }

    func testSearchCharactersAreNotPatterns() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "abc")
        await model.flushPendingDrafts()

        model.setSearchText("a.c")
        await model.pendingSearch?.value
        XCTAssertTrue(model.listedNotes.isEmpty)
    }
}

/// Trash and restore at the model level: selection, pending text, failures, and read-only trashed notes.
@MainActor
final class TrashModelTests: XCTestCase {
    func testTrashMovesSelectionToNeighborAndKeepsPendingText() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        await model.createNote()
        let secondID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: secondID, title: "Pending before trash")

        let trashed = await model.trashNote(secondID)

        XCTAssertTrue(trashed)
        XCTAssertEqual(model.deletedNotes.map(\.id), [secondID])
        XCTAssertEqual(model.deletedNotes.first?.title, "Pending before trash", "Pending text is saved before trashing.")
        XCTAssertEqual(model.selectedNoteID, fixture.noteID, "Selection moves to the neighboring note.")
    }

    func testTrashIsRefusedWhileSaveFails() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        await fixture.faulty.failNextUpdates(1)
        model.updateDraft(for: fixture.noteID, title: "Unsaved")

        let trashed = await model.trashNote(fixture.noteID)

        XCTAssertFalse(trashed)
        XCTAssertTrue(model.deletedNotes.isEmpty)
        XCTAssertTrue(model.hasUnsavedChanges, "The draft must survive a refused trash.")
    }

    func testFailedRestoreLeavesNoteInRecentlyDeleted() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        _ = await model.trashNote(fixture.noteID)
        await fixture.faulty.failNextStructuralWrites(1)

        let restored = await model.restoreNote(fixture.noteID)

        XCTAssertFalse(restored)
        XCTAssertNotNil(model.operationError)
        XCTAssertEqual(model.deletedNotes.map(\.id), [fixture.noteID])
    }

    func testTrashedNoteCannotBeEdited() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        _ = await model.trashNote(fixture.noteID)
        await model.requestSidebarSelection(.recentlyDeleted)
        await model.requestNoteSelection(fixture.noteID)
        let trashed = try XCTUnwrap(model.selectedNote)

        model.updateDraft(for: trashed.id, title: "Should not change")

        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.draft(for: trashed).title, trashed.title)
    }

    func testRestoreReturnsNoteToItsFolder() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        let work = try await model.createFolder(named: "Work")
        await model.createNote()
        let workNoteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: workNoteID, title: "Work note")
        await model.flushPendingDrafts()
        _ = await model.trashNote(workNoteID)

        await model.requestSidebarSelection(.recentlyDeleted)
        _ = await model.restoreNote(workNoteID)

        XCTAssertEqual(model.notes.first { $0.id == workNoteID }?.folderID, work.id)
        XCTAssertTrue(model.deletedNotes.isEmpty)
    }

    func testCreatingFromRecentlyDeletedShowsTheNewNote() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        _ = await model.trashNote(fixture.noteID)
        await model.requestSidebarSelection(.recentlyDeleted)

        await model.createNote()

        XCTAssertEqual(model.sidebarSelection, .allNotes)
        let created = try XCTUnwrap(model.selectedNoteID)
        XCTAssertTrue(model.visibleNotes.contains { $0.id == created })
    }

    func testSearchCoversRecentlyDeletedOnlyWhenSelected() async throws {
        let fixture = try await SaveFixture.makeFixture(in: self)
        let model = fixture.model
        model.updateDraft(for: fixture.noteID, title: "needle in trash")
        await model.flushPendingDrafts()
        _ = await model.trashNote(fixture.noteID)

        model.setSearchText("needle")
        await model.pendingSearch?.value
        XCTAssertTrue(model.listedNotes.isEmpty, "Active search must not return trashed notes.")

        await model.requestSidebarSelection(.recentlyDeleted)
        XCTAssertEqual(model.listedNotes.map(\.id), [fixture.noteID])
    }
}
