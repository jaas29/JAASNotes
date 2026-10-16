import XCTest

/// End-to-end editing on a temporary library. Never touches the real Application Support library.
final class NoteEditingUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self, extraEnvironment: extraEnvironment)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))
        return app
    }

    /// Switching notes waits for the pending save, so the editor updates a moment after the click.
    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Rows combine their text into one static text whose value holds title, date, and preview.
    @MainActor
    private func noteRow(in app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", prefix)
        ).firstMatch
    }

    @MainActor
    func testCreateEditSwitchAndKeepDrafts() throws {
        let app = launchApp()

        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Café 🧪")

        let body = app.textViews["noteBody"]
        body.click()
        body.typeText("Línea uno\n日本語")

        app.buttons["New Note"].firstMatch.click()
        let secondTitle = app.textFields["noteTitle"]
        XCTAssertTrue(secondTitle.waitForExistence(timeout: 5))
        // Focus on a new note is best-effort, so click the field the way a user would before typing.
        secondTitle.click()
        secondTitle.typeText("Second")

        // Switching back to the first note must show its unsaved draft.
        noteRow(in: app, startingWith: "Café").click()
        XCTAssertTrue(waitForValue(app.textFields["noteTitle"], "Café 🧪"))
        XCTAssertTrue((app.textViews["noteBody"].value as? String ?? "").contains("日本語"))
    }

    @MainActor
    func testNativeUndoRevertsBodyTyping() throws {
        let app = launchApp()

        app.buttons["New Note"].firstMatch.click()
        let body = app.textViews["noteBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.click()
        body.typeText("Keep")
        body.typeKey("z", modifierFlags: .command)

        XCTAssertEqual((body.value as? String) ?? "", "")
    }

    @MainActor
    func testEditsSurviveQuitAndRelaunch() throws {
        let app = launchApp()
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Persisted title")
        app.typeKey("s", modifierFlags: .command)
        app.terminate()

        let relaunched = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(relaunched.staticTexts["All Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(noteRow(in: relaunched, startingWith: "Persisted title").waitForExistence(timeout: 5),
                      "The saved note should appear after relaunch.")
    }

    @MainActor
    func testTypingJustBeforeQuitIsSaved() throws {
        let app = launchApp()
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // No explicit save: quitting right away must flush the draft before the app exits.
        title.typeText("Quit flush title")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        let relaunched = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(relaunched.staticTexts["All Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(noteRow(in: relaunched, startingWith: "Quit flush title").waitForExistence(timeout: 5),
                      "A draft typed just before quit should be saved.")
    }

    @MainActor
    func testFailedSaveCancelsQuitAndKeepsDraft() throws {
        // Every write fails in this run, so quitting must be cancelled and the failure shown.
        let app = launchApp(extraEnvironment: ["JAASNOTES_TEST_FAIL_SAVES": "1"])
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Unsaved title")
        XCTAssertTrue(app.staticTexts["Not saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Changes Not Saved"].waitForExistence(timeout: 5),
                      "A failed save should explain the failure.")

        app.typeKey("q", modifierFlags: .command)

        // Quit is cancelled: the app keeps running, and the draft and failure status remain.
        XCTAssertEqual(app.state, .runningForeground, "Quit must be cancelled while the save is failing.")
        XCTAssertEqual(app.textFields["noteTitle"].value as? String, "Unsaved title")
        XCTAssertTrue(app.staticTexts["Not saved"].exists)
    }

    @MainActor
    func testDiscardRequiresConfirmationAndReturnsToStoredText() throws {
        let app = launchApp(extraEnvironment: ["JAASNOTES_TEST_FAIL_SAVES": "1"])
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Unwanted title")
        XCTAssertTrue(app.staticTexts["Not saved"].waitForExistence(timeout: 5))
        // The failure alert covers the window until it is dismissed.
        XCTAssertTrue(app.staticTexts["Changes Not Saved"].waitForExistence(timeout: 5))
        app.sheets.buttons["OK"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Changes Not Saved"].waitForNonExistence(timeout: 5))

        app.buttons["discardUnsaved"].click()
        let confirmDiscard = app.sheets.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        confirmDiscard.click()

        XCTAssertFalse(app.staticTexts["Not saved"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["noteTitle"].value as? String, "")
    }
}

/// Folder rename, note move, and empty folder states through the real window, checked again after relaunch.
final class FolderUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testFolderRenameMoveAndEmptyStateSurviveRelaunch() throws {
        let app = launchApp()

        // Create and rename a folder through the sheet.
        app.buttons["newFolderButton"].firstMatch.click()
        let nameField = app.textFields["folderNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Work")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Work"].firstMatch.waitForExistence(timeout: 5))

        app.staticTexts["Work"].firstMatch.rightClick()
        app.menuItems["Rename Folder…"].firstMatch.click()
        let renameField = app.textFields["folderNameField"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.click()
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Projects")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Projects"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Work"].firstMatch.exists)

        // A note created while Projects is selected belongs to Projects.
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Plan")
        app.typeKey("s", modifierFlags: .command)

        // Move it to Notes with the Move To toolbar menu.
        // The row's context menu lists the same folders as the toolbar menu, and it opens reliably on CI runners.
        let row = app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", "Plan")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        app.menuItems["Notes"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No Notes in This Folder"].waitForExistence(timeout: 5),
                      "Projects should be empty after the move.")

        app.terminate()

        let relaunched = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(relaunched.staticTexts["All Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(relaunched.staticTexts["Projects"].firstMatch.waitForExistence(timeout: 5),
                      "The renamed folder should survive relaunch.")
        relaunched.staticTexts["Projects"].firstMatch.click()
        XCTAssertTrue(relaunched.staticTexts["No Notes in This Folder"].waitForExistence(timeout: 5))
    }
}

/// Search through the real search field, with a Unicode query and an empty result.
final class SearchUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchFindsUnicodeAndShowsEmptyResults() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))

        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Café de Mañana")
        app.typeKey("s", modifierFlags: .command)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("cafe")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", "Café")
        ).firstMatch.waitForExistence(timeout: 5), "A diacritic-free query should find the accented title.")

        search.typeKey("a", modifierFlags: .command)
        search.typeText("zzz-no-match")
        // The empty-state text is exposed as the value of a static text in the note list.
        let emptyResults = app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteList' AND value BEGINSWITH %@", "No Results")
        ).firstMatch
        XCTAssertTrue(emptyResults.waitForExistence(timeout: 5),
                      "A query with no matches should show an empty result state.")
    }
}

/// Delete and restore through the real window, with a relaunch while the note sits in Recently Deleted.
final class TrashUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func noteRow(in app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", prefix)
        ).firstMatch
    }

    @MainActor
    func testDeletedNoteSurvivesRelaunchAndCanBeRestored() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))

        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Gone note")
        app.typeKey("s", modifierFlags: .command)

        app.buttons["toolbarDelete"].firstMatch.click()
        app.staticTexts["Recently Deleted"].firstMatch.click()
        XCTAssertTrue(noteRow(in: app, startingWith: "Gone note").waitForExistence(timeout: 5))

        app.terminate()

        let relaunched = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(relaunched.staticTexts["Recently Deleted"].firstMatch.waitForExistence(timeout: 10))
        relaunched.staticTexts["Recently Deleted"].firstMatch.click()
        let trashedRow = noteRow(in: relaunched, startingWith: "Gone note")
        XCTAssertTrue(trashedRow.waitForExistence(timeout: 5), "The deleted note should survive relaunch.")
        trashedRow.click()
        XCTAssertTrue(relaunched.staticTexts["trashStatus"].waitForExistence(timeout: 5))

        relaunched.buttons["toolbarRestore"].firstMatch.click()
        XCTAssertFalse(trashedRow.waitForExistence(timeout: 1), "A restored note leaves Recently Deleted.")

        relaunched.staticTexts["All Notes"].firstMatch.click()
        XCTAssertTrue(noteRow(in: relaunched, startingWith: "Gone note").waitForExistence(timeout: 5),
                      "The restored note should be back in All Notes.")
    }
}

/// Menu shortcuts and the rule that Cmd-Delete belongs to the text while the caret is in an editor.
final class KeyboardUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func noteRow(in app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", prefix)
        ).firstMatch
    }

    @MainActor
    func testShiftCommandNOpensTheNewFolderSheet() throws {
        let app = launchApp()
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.textFields["folderNameField"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCommandDeleteInTheBodyEditsTextAndKeepsTheNote() throws {
        let app = launchApp()
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Keep this note")
        app.typeKey("s", modifierFlags: .command)

        let body = app.textViews["noteBody"]
        body.click()
        body.typeText("some words")
        app.typeKey(.delete, modifierFlags: .command)

        XCTAssertTrue(noteRow(in: app, startingWith: "Keep this").waitForExistence(timeout: 5),
                      "Cmd-Delete in the editor must not move the note to Recently Deleted.")
    }

    @MainActor
    func testCommandDeleteInTheNoteListMovesTheSelectedNote() throws {
        let app = launchApp()
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Trash via key")
        app.typeKey("s", modifierFlags: .command)

        noteRow(in: app, startingWith: "Trash via key").click()
        app.typeKey(.delete, modifierFlags: .command)

        XCTAssertFalse(noteRow(in: app, startingWith: "Trash via key").waitForExistence(timeout: 2),
                       "Cmd-Delete with the note list focused should move the note to Recently Deleted.")
        app.staticTexts["Recently Deleted"].firstMatch.click()
        XCTAssertTrue(noteRow(in: app, startingWith: "Trash via key").waitForExistence(timeout: 5))
    }

    @MainActor
    func testShiftCommandFFocusesSearch() throws {
        let app = launchApp()
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: search)], timeout: 5) == .completed,
            "Shift-Cmd-F should put the caret in the search field."
        )
    }
}

/// Matrix item 6: a save that was acknowledged survives a hard kill (SIGKILL), with no chance to flush on exit.
final class ForceQuitUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSavedNoteSurvivesForceTermination() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Survives kill")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))

        // forceTerminate sends SIGKILL: no quit handler runs and nothing is flushed on exit.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.jaasnotes.JAASNotes")
        XCTAssertEqual(running.count, 1)
        running.first?.forceTerminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        let relaunched = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(relaunched.staticTexts["All Notes"].waitForExistence(timeout: 10))
        let row = relaunched.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", "Survives kill")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "A saved note must survive a force quit.")
    }
}

/// Matrix item 6, pending case: a kill while text is still unsaved may lose that text, but the library must still open.
final class PendingSaveKillUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testKillWithUnsavedTextLeavesALibraryThatOpens() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))
        app.buttons["New Note"].firstMatch.click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Saved first")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))

        // Type immediately and kill before the 0.5 s autosave can run.
        title.typeText(" and unsaved")
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.jaasnotes.JAASNotes")
        running.first?.forceTerminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        let relaunched = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(relaunched.staticTexts["All Notes"].waitForExistence(timeout: 10), "The library must open after a kill.")
        let row = relaunched.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", "Saved first")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The acknowledged save must still be there.")
    }
}

final class FormatUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    @MainActor
    func testFormatMenuOffersTheTextCommands() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))

        app.menuBarItems["Format"].click()

        for item in ["Bold", "Italic", "Underline", "Heading 1", "Heading 2", "Heading 3", "Body Text", "Bulleted List"] {
            XCTAssertTrue(app.menuItems[item].exists, "The Format menu should offer \(item).")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testChecklistIsAddedAndCheckedFromTheKeyboard() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))

        app.buttons["New Note"].firstMatch.click()
        let body = app.textViews["noteBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.click()
        body.typeText("Milk")

        app.typeKey("c", modifierFlags: [.command, .shift])
        let box = app.checkBoxes["checklistItem"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "Checklist should add a checkbox for the paragraph.")
        XCTAssertEqual(box.value as? Int, 0, "A new item starts unchecked.")

        // Checkbox values are numbers (0 or 1), so the predicate compares numerically.
        app.typeKey(.return, modifierFlags: [.command, .shift])
        let checked = NSPredicate(format: "value == 1")
        expectation(for: checked, evaluatedWith: box)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testChecklistLayoutScreenshot() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))

        app.buttons["New Note"].firstMatch.click()
        let body = app.textViews["noteBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.click()
        body.typeText("Buy milk\nEggs and a much longer line of checklist text that should wrap onto a second line\nBread")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.checkBoxes["checklistItem"].firstMatch.waitForExistence(timeout: 5))
        app.checkBoxes.matching(identifier: "checklistItem").element(boundBy: 1).click()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "checklist-layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
