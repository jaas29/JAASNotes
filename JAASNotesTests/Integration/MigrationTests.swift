import CoreData
import SQLite3
import XCTest
@testable import JAASNotes

/// Schema migration from version 1 (the released model) to the current version, using the embedded v1 fixture.
@MainActor
final class MigrationTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func makeLocation() -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(root)
        return LibraryLocation(rootURL: root)
    }

    /// Writes the embedded version-1 library into `location`.
    private func installVersionOneFixture(_ location: LibraryLocation) throws {
        try FileManager.default.createDirectory(at: location.libraryDirectoryURL, withIntermediateDirectories: true)
        try V1LibraryFixture.storeData.write(to: location.storeURL)
    }

    func testVersionOneLibraryOpensUpgradedWithContentUnchanged() async throws {
        let location = makeLocation()
        try installVersionOneFixture(location)

        let model = LibraryModel()
        await model.load(at: location)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.notes.map(\.title).sorted(), ["Café de Mañana 🧪", "Plan"])
        let first = try XCTUnwrap(model.notes.first { $0.title.hasPrefix("Café") })
        XCTAssertEqual(first.bodyPlainText, "Línea uno\n日本語のメモ, edited")
        XCTAssertEqual(first.revision, 2, "Revisions from version 1 are kept.")
        XCTAssertFalse(first.isPinned, "Upgraded notes start unpinned.")
        XCTAssertEqual(model.deletedNotes.map(\.title), ["Old"], "Recently Deleted survives the upgrade.")
        XCTAssertEqual(model.folders.map(\.name).sorted(), ["Notes", "Work"])
        XCTAssertTrue(model.backups.contains { $0.kind == .preMigration }, "A backup is taken before the upgrade.")
    }

    func testUpgradeInterruptedBeforeInstallLeavesTheOriginalAndCanBeRetried() async throws {
        let location = makeLocation()
        try installVersionOneFixture(location)
        let before = try Data(contentsOf: location.storeURL)

        do {
            _ = try await LibraryMigrationService.migrateIfNeeded(location, takeBackup: false, fault: .afterUpgrade)
            XCTFail("The interruption must stop the upgrade.")
        } catch LibraryBackupError.simulatedInterruption {
        }
        XCTAssertEqual(try Data(contentsOf: location.storeURL), before, "The original must not change before install.")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: LibraryBackupService.stagingDirectory(in: location).path)
        XCTAssertTrue(leftovers.isEmpty, "The partial upgrade must be removed.")

        let upgraded = try await LibraryMigrationService.migrateIfNeeded(location, takeBackup: false)
        XCTAssertTrue(upgraded, "A later attempt succeeds.")
        XCTAssertFalse(try CoreDataStack.isCompatible(location.storeURL, with: try CoreDataStack.model(named: "JAASNotes")),
                       "After the upgrade the library is no longer a version-1 store.")
    }

    func testUnknownFileIsRefusedUnchanged() async throws {
        let location = makeLocation()
        try FileManager.default.createDirectory(at: location.libraryDirectoryURL, withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(location.storeURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE Unrelated (x INTEGER);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: location.storeURL)

        do {
            _ = try await LibraryMigrationService.migrateIfNeeded(location)
            XCTFail("An unknown file must not be upgraded.")
        } catch LibraryError.storeLoadFailed {
        }
        XCTAssertEqual(try Data(contentsOf: location.storeURL), before)
    }

    func testCurrentLibraryIsNotUpgradedOrBackedUp() async throws {
        let location = makeLocation()
        let container = try await CoreDataStack.openContainer(at: location)
        _ = try await LibraryRepository(container: container).initializeLibraryIfNeeded()
        try CoreDataStack.close(container)

        let upgraded = try await LibraryMigrationService.migrateIfNeeded(location)

        XCTAssertFalse(upgraded)
        XCTAssertEqual(try LibraryBackupService.list(in: location).filter { $0.kind == .preMigration }.count, 0)
    }
}
