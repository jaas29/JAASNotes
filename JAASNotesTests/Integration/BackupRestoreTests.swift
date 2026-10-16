import CoreData
import CryptoKit
import SQLite3
import XCTest
@testable import JAASNotes

/// Backups, restores, interrupted swaps, and store-open failures against real SQLite libraries in temporary folders.
@MainActor
final class BackupRestoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    private func makeLocation(_ name: String = "lib") -> LibraryLocation {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "JAASNotesTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        roots.append(root)
        return LibraryLocation(rootURL: root)
    }

    /// Creates a populated library with one folder and two notes, then closes it.
    private func makePopulatedLibrary(_ location: LibraryLocation, titles: [String]) async throws {
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        _ = try await repository.initializeLibraryIfNeeded()
        let folderID = try await repository.folders()[0].id
        for title in titles {
            _ = try await repository.createNote(inFolder: folderID, title: title, bodyPlainText: "Body of \(title) 🧪")
        }
        try CoreDataStack.close(container)
    }

    /// Reads the titles of active notes in a closed library, then closes it again.
    private func titles(in location: LibraryLocation) async throws -> [String] {
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        return try await LibraryRepository(container: container).activeNotes(inFolder: nil).map(\.title).sorted()
    }

    private func snapshot(_ location: LibraryLocation, kind: BackupKind = .manual, at date: Date = Date()) async throws -> BackupSummary {
        try await LibraryBackupService.createSnapshot(of: location, kind: kind, now: date, lastChangeAt: nil)
    }

    // MARK: - Snapshot and restore

    func testSnapshotRestoresIntoAFreshLibrary() async throws {
        let source = makeLocation("source")
        try await makePopulatedLibrary(source, titles: ["Alpha", "Βeta 日本", "Gamma"])
        let backup = try await snapshot(source)
        XCTAssertEqual(backup.counts, BackupCounts(folders: 1, activeNotes: 3, deletedNotes: 0))

        let fresh = makeLocation("fresh")
        try await LibraryRestoreService.restore(backup, into: fresh)

        let restored = try await titles(in: fresh)
        XCTAssertEqual(restored, ["Alpha", "Gamma", "Βeta 日本"])
    }

    func testRestoreReplacesPopulatedLibraryAndKeepsThePreviousOneInRecovery() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["Kept", "Dropped later"])
        let backup = try await snapshot(location)

        // Change the library after the backup: add a note and remove the one that was backed up.
        let container = try await CoreDataStack.openContainer(at: location)
        let repository = LibraryRepository(container: container)
        let notes = try await repository.activeNotes(inFolder: nil)
        let folderID = try await repository.folders()[0].id
        _ = try await repository.createNote(inFolder: folderID, title: "Added after backup", bodyPlainText: "")
        try CoreDataStack.close(container)

        try await LibraryRestoreService.restore(backup, into: location)

        let value0 = try await titles(in: location)
        XCTAssertEqual(value0, ["Dropped later", "Kept"])
        let previous = try LibraryBackupService.recoveryDirectory(in: location)
        let recoveredFiles = try FileManager.default.subpathsOfDirectory(atPath: previous.path)
        XCTAssertTrue(recoveredFiles.contains { $0.hasSuffix("Store.sqlite") }, "The replaced library must be kept, not deleted.")
        XCTAssertEqual(notes.count, 2)
    }

    func testRestoreReturnsSameNoteIdentities() async throws {
        let source = makeLocation("ids")
        try await makePopulatedLibrary(source, titles: ["Identity"])
        let container = try await CoreDataStack.openContainer(at: source)
        let originalID = try await LibraryRepository(container: container).activeNotes(inFolder: nil).first?.id
        try CoreDataStack.close(container)
        let backup = try await snapshot(source)

        let fresh = makeLocation("ids-fresh")
        try await LibraryRestoreService.restore(backup, into: fresh)

        let restoredContainer = try await CoreDataStack.openContainer(at: fresh)
        defer { try? CoreDataStack.close(restoredContainer) }
        let restoredID = try await LibraryRepository(container: restoredContainer).activeNotes(inFolder: nil).first?.id
        XCTAssertEqual(restoredID, originalID)
    }

    // MARK: - Verification

    func testManifestChecksumsCatchADamagedBackupBeforeAnyChange() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["Safe"])
        let backup = try await snapshot(location)

        let copy = backup.url.appending(path: "Library/Store.sqlite", directoryHint: .notDirectory)
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("damage".utf8))
        try handle.close()

        let target = makeLocation("target")
        try await makePopulatedLibrary(target, titles: ["Untouched"])
        do {
            try await LibraryRestoreService.restore(backup, into: target)
            XCTFail("A damaged backup must not be used.")
        } catch LibraryBackupError.checksumMismatch {
        }
        let value1 = try await titles(in: target)
        XCTAssertEqual(value1, ["Untouched"])
    }

    func testBackupFromANewerFormatIsRefusedWithoutChangingTheLibrary() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["Current"])
        let backup = try await snapshot(location)

        // Rewrite the manifest as if a newer app had made it.
        let manifestURL = backup.url.appending(path: "manifest.json", directoryHint: .notDirectory)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        object["formatVersion"] = BackupManifest.supportedFormatVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)

        do {
            try await LibraryRestoreService.restore(backup, into: location)
            XCTFail("A newer backup format must be refused.")
        } catch LibraryBackupError.unsupportedBackupFormat {
        }
        let value2 = try await titles(in: location)
        XCTAssertEqual(value2, ["Current"])
    }

    func testListIgnoresPackagesWithoutAValidManifest() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["One"])
        _ = try await snapshot(location)

        let abandoned = LibraryBackupService.backupsDirectory(in: location)
            .appending(path: "interrupted-package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)

        XCTAssertEqual(try LibraryBackupService.list(in: location).count, 1)
    }

    // MARK: - Interrupted restores

    func testInterruptionAfterMovingLibraryAsideRestoresTheOriginalAtStartup() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["Original"])
        let backup = try await snapshot(location)
        try await makePopulatedLibrary(location, titles: ["Second"])

        let target = makeLocation("interrupted")
        try await makePopulatedLibrary(target, titles: ["Before crash"])
        do {
            try await LibraryRestoreService.restore(backup, into: target, interruptAt: .afterMovingLibraryAside)
            XCTFail("The interruption must stop the restore.")
        } catch LibraryBackupError.simulatedInterruption {
        }

        // The app starts again: the pending transaction is finished or undone before the library opens.
        try await LibraryRestoreService.recoverInterruptedRestore(at: target)
        let value3 = try await titles(in: target)
        XCTAssertEqual(value3, ["Before crash"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.rootURL.appending(path: "Staging/restore-transaction.json").path))
    }

    func testInterruptionAfterInstallingBackupCompletesTheRestoreAtStartup() async throws {
        let source = makeLocation("source-install")
        try await makePopulatedLibrary(source, titles: ["From backup"])
        let backup = try await snapshot(source)

        let target = makeLocation("install")
        try await makePopulatedLibrary(target, titles: ["Replaced"])
        do {
            try await LibraryRestoreService.restore(backup, into: target, interruptAt: .afterInstallingBackup)
            XCTFail("The interruption must stop the restore.")
        } catch LibraryBackupError.simulatedInterruption {
        }

        try await LibraryRestoreService.recoverInterruptedRestore(at: target)
        let value4 = try await titles(in: target)
        XCTAssertEqual(value4, ["From backup"])
        let previous = try FileManager.default.subpathsOfDirectory(
            atPath: LibraryBackupService.recoveryDirectory(in: target).path
        )
        XCTAssertTrue(previous.contains { $0.hasSuffix("Store.sqlite") }, "The replaced library must still be kept.")
    }

    // MARK: - Damaged and unsupported libraries

    func testCorruptLibraryIsNeverReplacedWithAnEmptyStore() async throws {
        let location = makeLocation("corrupt")
        try FileManager.default.createDirectory(at: location.libraryDirectoryURL, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: location.storeURL)
        let before = try Data(contentsOf: location.storeURL)

        let model = LibraryModel()
        await model.load(at: location)

        guard case .failed = model.phase else { return XCTFail("A corrupt store must show the recovery screen.") }
        XCTAssertEqual(try Data(contentsOf: location.storeURL), before, "The corrupt store must be left as it was.")
    }

    func testForeignSQLiteFileIsRefusedWithoutBeingGivenCoreDataTables() async throws {
        let location = makeLocation("foreign")
        try makeForeignSQLiteFile(location)
        let before = try Data(contentsOf: location.storeURL)

        let model = LibraryModel()
        await model.load(at: location)

        guard case .failed = model.phase else { return XCTFail("A foreign file must not open as an empty library.") }
        XCTAssertEqual(try Data(contentsOf: location.storeURL), before, "The file must not be changed.")
        XCTAssertTrue(model.notes.isEmpty)
    }

    func testCreateNewLibraryPreservesTheOldOneAndOpensAnEmptyLibrary() async throws {
        let location = makeLocation("create-new")
        try FileManager.default.createDirectory(at: location.libraryDirectoryURL, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: location.storeURL)

        let model = LibraryModel()
        await model.load(at: location)
        let created = await model.createNewLibraryPreservingExisting()
        XCTAssertTrue(created)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.notes.count, 0)
        let preserved = try FileManager.default.subpathsOfDirectory(
            atPath: LibraryBackupService.recoveryDirectory(in: location).path
        )
        XCTAssertTrue(preserved.contains { $0.hasSuffix("Store.sqlite") }, "The old library must be kept in Recovery.")
    }

    /// Writes a SQLite file with an unrelated schema. It is not a JAASNotes library and must not get Core Data tables.
    private func makeForeignSQLiteFile(_ location: LibraryLocation) throws {
        try FileManager.default.createDirectory(at: location.libraryDirectoryURL, withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(location.storeURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE Unrelated (x INTEGER); INSERT INTO Unrelated VALUES (7);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
    }

    // MARK: - Retention and automatic backups

    func testAutomaticRetentionKeepsSevenAndNeverPrunesManualBackups() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["Retention"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let manual = try await snapshot(location, kind: .manual, at: base)
        for day in 0..<9 {
            _ = try await snapshot(location, kind: .automatic, at: base.addingTimeInterval(Double(day) * 86_400))
            try LibraryBackupService.pruneAutomaticBackups(in: location)
        }

        let all = try LibraryBackupService.list(in: location)
        XCTAssertEqual(all.filter { $0.kind == .automatic }.count, 7)
        XCTAssertTrue(all.contains { $0.id == manual.id }, "Manual backups are never pruned.")
        let newestAutomatic = all.filter { $0.kind == .automatic }.map(\.createdAt).max()
        XCTAssertEqual(newestAutomatic, base.addingTimeInterval(8 * 86_400), "The newest automatic backups are kept.")
    }

    func testExportedBackupIsACompleteCheckedCopy() async throws {
        let location = makeLocation()
        try await makePopulatedLibrary(location, titles: ["Exported"])
        let backup = try await snapshot(location)
        let destination = makeLocation("export-destination").rootURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let model = LibraryModel()
        XCTAssertTrue(model.exportBackup(backup, to: destination))

        let copied = destination.appending(path: backup.url.lastPathComponent, directoryHint: .isDirectory)
        let manifest = try LibraryBackupService.readManifest(in: copied)
        XCTAssertEqual(manifest.backupID, backup.id)
        try LibraryBackupService.verifyChecksums(of: manifest, in: copied)
        let restoredLocation = makeLocation("from-export")
        try await LibraryRestoreService.restore(
            BackupSummary(id: backup.id, kind: backup.kind, createdAt: backup.createdAt, counts: backup.counts, url: copied),
            into: restoredLocation
        )
        let restoredTitles = try await titles(in: restoredLocation)
        XCTAssertEqual(restoredTitles, ["Exported"])
    }

    func testAutomaticBackupRunsOncePerDayAndOnlyAfterAChange() async throws {
        let location = makeLocation()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let model = LibraryModel(clock: { clock.now })
        await model.load(at: location)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: noteID, title: "First change")
        await model.flushPendingDrafts()

        await model.performAutomaticBackupIfDue()
        XCTAssertEqual(model.backups.filter { $0.kind == .automatic }.count, 1)

        clock.now = clock.now.addingTimeInterval(3_600)
        await model.performAutomaticBackupIfDue()
        XCTAssertEqual(model.backups.filter { $0.kind == .automatic }.count, 1, "At most one automatic backup a day.")

        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        await model.performAutomaticBackupIfDue()
        XCTAssertEqual(model.backups.filter { $0.kind == .automatic }.count, 1, "No change since the last backup.")

        model.updateDraft(for: noteID, title: "Second change")
        await model.flushPendingDrafts()
        clock.now = clock.now.addingTimeInterval(60)
        await model.performAutomaticBackupIfDue()
        XCTAssertEqual(model.backups.filter { $0.kind == .automatic }.count, 2)
    }

    func testRestoreFromTheAppTakesAPreRestoreBackupFirst() async throws {
        let location = makeLocation()
        let model = LibraryModel()
        await model.load(at: location)
        await model.createNote()
        let noteID = try XCTUnwrap(model.selectedNoteID)
        model.updateDraft(for: noteID, title: "Saved before restore")
        await model.flushPendingDrafts()
        let backup = try await LibraryBackupService.createSnapshot(of: location, kind: .manual, now: Date(), lastChangeAt: nil)
        await model.load(at: location)

        model.updateDraft(for: noteID, title: "Unsaved edit")
        let restored = await model.restoreBackup(backup)
        XCTAssertTrue(restored)

        XCTAssertTrue(model.backups.contains { $0.kind == .preRestore }, "The current library is backed up before a restore.")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.hasUnsavedChanges, "Drafts were replaced by the restored library.")
    }
}
