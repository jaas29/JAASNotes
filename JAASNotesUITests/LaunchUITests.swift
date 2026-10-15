import XCTest

final class LaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsThreeColumnShell() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recently Deleted"].exists)
        XCTAssertTrue(app.staticTexts["No Notes"].exists)
    }
}
