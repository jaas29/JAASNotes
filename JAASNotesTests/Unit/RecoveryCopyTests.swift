import XCTest
@testable import JAASNotes

final class RecoveryCopyTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "recovery-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func sample() -> [RecoveryDraft] {
        [
            RecoveryDraft(
                noteID: UUID(),
                folderID: UUID(),
                title: "Café 🧪",
                bodyPlainText: "Decomposed e\u{0301}\n日本語 👩🏽‍💻",
                savedRevision: 3
            ),
        ]
    }

    func testWriteThenReadReturnsTheSameDrafts() throws {
        let drafts = sample()
        try RecoveryCopy.write(drafts, to: url, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(try RecoveryCopy.read(from: url), drafts)
    }

    func testTextIsPreservedByScalar() throws {
        let drafts = sample()
        try RecoveryCopy.write(drafts, to: url, exportedAt: Date())

        let body = try XCTUnwrap(RecoveryCopy.read(from: url).first?.bodyPlainText)
        XCTAssertEqual(Array(body.unicodeScalars), Array(drafts[0].bodyPlainText.unicodeScalars))
    }

    func testForeignFileIsRejected() throws {
        try Data(#"{"format":"something-else","version":1,"exportedAt":"2023-11-14T22:13:20Z","drafts":[]}"#.utf8)
            .write(to: url)

        XCTAssertThrowsError(try RecoveryCopy.read(from: url)) { error in
            XCTAssertEqual(error as? RecoveryCopyError, .verificationFailed)
        }
    }

    func testWriteToMissingFolderReportsWriteFailure() {
        let unwritable = url.deletingLastPathComponent()
            .appending(path: "missing-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "recovery.json")

        XCTAssertThrowsError(try RecoveryCopy.write(sample(), to: unwritable, exportedAt: Date())) { error in
            XCTAssertEqual(error as? RecoveryCopyError, .writeFailed)
        }
    }
}
