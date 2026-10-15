import XCTest
@testable import JAASNotes

/// Exercises the app-level model against real temporary SQLite libraries.
@MainActor
final class LibraryModelTests: XCTestCase {
    /// A fresh library per test. The directory is removed when the test ends.
    private func makeLocation() -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
        return LibraryLocation(rootURL: root)
    }

    func testOpeningCreatesTheDefaultFolderAndAnEmptyList() async {
        let location = makeLocation()
        let model = LibraryModel()
        await model.load(at: location)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.folders.map(\.name), ["Notes"])
        XCTAssertTrue(model.visibleNotes.isEmpty)
    }

    func testCreatingNotesSelectsEachNewNoteAndRequestsTitleFocus() async throws {
        let location = makeLocation()
        let model = LibraryModel()
        await model.load(at: location)

        await model.createNote()
        let first = try XCTUnwrap(model.selectedNoteID)
        XCTAssertEqual(model.titleFocusRequest, first)

        await model.createNote()
        let second = try XCTUnwrap(model.selectedNoteID)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.visibleNotes.count, 2)
    }

    func testNewNotesGoToTheDefaultFolderWhenAllNotesIsSelected() async throws {
        let location = makeLocation()
        let model = LibraryModel()
        await model.load(at: location)
        let defaultFolderID = try XCTUnwrap(model.folders.first(where: \.isDefault)?.id)

        model.sidebarSelection = .allNotes
        await model.createNote()

        XCTAssertEqual(model.notes.first?.folderID, defaultFolderID)
    }

    func testDraftsSurviveSwitchingNotes() async throws {
        let location = makeLocation()
        let model = LibraryModel()
        await model.load(at: location)

        await model.createNote()
        let firstID = try XCTUnwrap(model.selectedNoteID)
        let firstNote = try XCTUnwrap(model.selectedNote)
        model.updateDraft(for: firstID, title: "Café 🧪", body: "Línea uno\n日本語")

        await model.createNote()
        let secondID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: secondID, title: "Second")

        model.selectedNoteID = firstID
        XCTAssertEqual(model.draft(for: firstNote), LibraryModel.Draft(title: "Café 🧪", bodyPlainText: "Línea uno\n日本語"))
        XCTAssertEqual(model.displayTitle(for: firstNote), "Café 🧪")

        model.selectedNoteID = secondID
        let secondNote = try XCTUnwrap(model.selectedNote)
        XCTAssertEqual(model.displayTitle(for: secondNote), "Second")
    }

    func testFailedOpenNeverReplacesAnExistingStore() async throws {
        let location = makeLocation()
        // A store file that is not a database must be reported and left exactly as it is.
        let libraryDirectory = location.libraryDirectoryURL
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let garbage = Data("not a database".utf8)
        try garbage.write(to: location.storeURL)

        let model = LibraryModel()
        await model.load(at: location)

        guard case .failed = model.phase else {
            return XCTFail("Expected the library to report a failure, got \(model.phase)")
        }
        XCTAssertEqual(try Data(contentsOf: location.storeURL), garbage)
    }
}
