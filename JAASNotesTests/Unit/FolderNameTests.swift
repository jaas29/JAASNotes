import XCTest
@testable import JAASNotes

final class FolderNameTests: XCTestCase {
    func testTrimsSurroundingWhitespaceAndKeepsDisplaySpelling() throws {
        let result = try FolderName.validated("  Café Ideas  ")
        XCTAssertEqual(result.displayName, "Café Ideas")
    }

    func testNormalizationIgnoresCaseAndDiacritics() {
        XCTAssertEqual(FolderName.normalize("CAFÉ"), FolderName.normalize("cafe"))
    }

    func testCanonicallyEquivalentSpellingsShareOneKey() {
        // "é" as one scalar versus "e" plus a combining accent.
        XCTAssertEqual(FolderName.normalize("Caf\u{00E9}"), FolderName.normalize("Cafe\u{0301}"))
    }

    func testDistinctNamesStayDistinct() {
        XCTAssertNotEqual(FolderName.normalize("Recipes"), FolderName.normalize("Receipts"))
        XCTAssertNotEqual(FolderName.normalize("日本語"), FolderName.normalize("日本"))
    }

    func testEmptyAndWhitespaceOnlyNamesAreRejected() {
        XCTAssertThrowsError(try FolderName.validated("")) { error in
            XCTAssertEqual(error as? LibraryError, .emptyFolderName)
        }
        XCTAssertThrowsError(try FolderName.validated(" \n\t ")) { error in
            XCTAssertEqual(error as? LibraryError, .emptyFolderName)
        }
    }

    func testVirtualFolderNamesAreReserved() {
        for name in ["All Notes", " recently DELETED ", "all notes"] {
            XCTAssertThrowsError(try FolderName.validated(name), name) { error in
                XCTAssertEqual(error as? LibraryError, .reservedFolderName)
            }
        }
    }
}
