import XCTest
@testable import JAASNotes

final class AppConfigurationTests: XCTestCase {
    /// The bundle identifier names the library location. Changing it later needs an explicit data migration.
    func testBundleIdentifierIsStable() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "org.jaasnotes.JAASNotes")
    }
}
