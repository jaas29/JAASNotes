import XCTest

final class LaunchUITests: XCTestCase {
    private let libraryName = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsThreeColumnShell() throws {
        let app = launchIsolatedApp(libraryName: libraryName, testCase: self)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Notes"].exists)
        XCTAssertTrue(app.staticTexts["No Notes"].exists)
    }
}
