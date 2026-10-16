import XCTest

/// Launches the app against a temporary library named for this test, and terminates the app when the test ends.
/// The library is created inside the app's sandbox temporary folder, never in Application Support.
@MainActor
func launchIsolatedApp(
    libraryName: String,
    testCase: XCTestCase,
    extraEnvironment: [String: String] = [:]
) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["JAASNOTES_TEST_LIBRARY_NAME"] = libraryName
    for (key, value) in extraEnvironment {
        app.launchEnvironment[key] = value
    }
    app.launch()
    // Bring the app forward and wait for its window. Without this, a launch can finish with no window.
    app.activate()
    _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    testCase.addTeardownBlock {
        await MainActor.run { app.terminate() }
    }
    return app
}
