import XCTest
@testable import JAASNotes

final class LibraryLocationTests: XCTestCase {
    func testStoreLivesInsideLibraryDirectory() {
        let root = URL(fileURLWithPath: "/tmp/example/JAASNotes", isDirectory: true)
        let location = LibraryLocation(rootURL: root)

        XCTAssertEqual(location.libraryDirectoryURL.path, "/tmp/example/JAASNotes/Library")
        XCTAssertEqual(location.storeURL.path, "/tmp/example/JAASNotes/Library/Store.sqlite")
    }

    func testDefaultRootIsNamedAfterTheApp() throws {
        let location = try LibraryLocation.applicationDefault()

        XCTAssertEqual(location.rootURL.lastPathComponent, "JAASNotes")
        XCTAssertEqual(location.rootURL.deletingLastPathComponent().lastPathComponent, "Application Support")
    }
}
