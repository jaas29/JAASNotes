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
