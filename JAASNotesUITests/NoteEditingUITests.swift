import XCTest

/// End-to-end editing on a temporary library. Never touches the real Application Support library.
final class NoteEditingUITests: XCTestCase {
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
        secondTitle.typeText("Second")

        // Switching back to the first note must show its unsaved draft.
        // Each row is one static text whose value combines title, date, and preview.
        let firstRow = app.staticTexts.matching(
            NSPredicate(format: "identifier == 'noteRow' AND value BEGINSWITH %@", "Café")
        ).firstMatch
        firstRow.click()
        XCTAssertEqual(app.textFields["noteTitle"].value as? String, "Café 🧪")
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
}
