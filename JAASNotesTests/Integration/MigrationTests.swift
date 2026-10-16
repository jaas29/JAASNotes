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

    /// Writes a version-2 library with the version-2 model itself: a pinned note, a trashed note, and Unicode text.
    private func installPriorLibrary(_ location: LibraryLocation, modelName: String, formatVersion: Int32) throws -> (pinnedID: UUID, trashedID: UUID) {
        try FileManager.default.createDirectory(at: location.libraryDirectoryURL, withIntermediateDirectories: true)
        let model = try CoreDataStack.model(named: modelName)
        let container = NSPersistentContainer(name: "JAASNotes", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: location.storeURL)
        description.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError)

        let context = container.viewContext
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = NSEntityDescription.insertNewObject(forEntityName: "LibraryMetadata", into: context)
        metadata.setValue(UUID(), forKey: "libraryID")
        metadata.setValue(date, forKey: "createdAt")
        metadata.setValue(formatVersion, forKey: "formatVersion")

        let folder = NSEntityDescription.insertNewObject(forEntityName: "Folder", into: context)
        let folderID = UUID()
        folder.setValue(folderID, forKey: "id")
        folder.setValue("Notes", forKey: "name")
        folder.setValue("notes", forKey: "normalizedName")
        folder.setValue(date, forKey: "createdAt")
        folder.setValue(date, forKey: "modifiedAt")
        folder.setValue(true, forKey: "isDefault")

        func note(_ id: UUID, title: String, body: String, pinned: Bool, deletedAt: Date?) {
            let record = NSEntityDescription.insertNewObject(forEntityName: "Note", into: context)
            record.setValue(id, forKey: "id")
            record.setValue(title, forKey: "title")
            record.setValue(body, forKey: "bodyPlainText")
            record.setValue(date, forKey: "createdAt")
            record.setValue(date, forKey: "modifiedAt")
            record.setValue(deletedAt, forKey: "deletedAt")
            record.setValue(Int64(3), forKey: "revision")
            record.setValue(pinned, forKey: "isPinned")
            record.setValue(folder, forKey: "folder")
        }
        let pinnedID = UUID()
        let trashedID = UUID()
        note(pinnedID, title: "Pinned ✓", body: "Body 日本語 🧪\nSecond line", pinned: true, deletedAt: nil)
        note(trashedID, title: "Trashed", body: "Gone", pinned: false, deletedAt: date)
        try context.save()
        try CoreDataStack.close(container)
        return (pinnedID, trashedID)
    }

    func testVersionThreeLibraryUpgradesWithContentUnchanged() async throws {
        let location = makeLocation()
        let ids = try installPriorLibrary(location, modelName: "JAASNotes 3", formatVersion: 3)

        let upgraded = try await LibraryMigrationService.migrateIfNeeded(location)

        XCTAssertTrue(upgraded)
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        let version = try await repository.libraryMetadata()?.formatVersion
        XCTAssertEqual(version, 4)
        let active = try await repository.activeNotes(inFolder: nil)
        let pinned = try XCTUnwrap(active.first { $0.id == ids.pinnedID })
        XCTAssertEqual(pinned.bodyPlainText, "Body 日本語 🧪\nSecond line")
        XCTAssertFalse(pinned.hasRichContent)
        let attachments = try await repository.allAttachments()
        XCTAssertTrue(attachments.isEmpty, "Version 3 had no attachments, so none appear.")
        let deleted = try await repository.deletedNotes().map(\.id)
        XCTAssertEqual(deleted, [ids.trashedID])
    }

    func testVersionTwoLibraryUpgradesWithPinsAndTextUnchanged() async throws {
        let location = makeLocation()
        let ids = try installPriorLibrary(location, modelName: "JAASNotes 2", formatVersion: 2)

        let upgraded = try await LibraryMigrationService.migrateIfNeeded(location)

        XCTAssertTrue(upgraded)
        let container = try await CoreDataStack.openContainer(at: location)
        defer { try? CoreDataStack.close(container) }
        let repository = LibraryRepository(container: container)
        let value1 = try await repository.libraryMetadata()?.formatVersion
        XCTAssertEqual(value1, LibraryRepository.currentFormatVersion)
        let active = try await repository.activeNotes(inFolder: nil)
        let pinned = try XCTUnwrap(active.first { $0.id == ids.pinnedID })
        XCTAssertTrue(pinned.isPinned, "Pins from version 2 are kept.")
        XCTAssertEqual(pinned.title, "Pinned ✓")
        XCTAssertEqual(pinned.bodyPlainText, "Body 日本語 🧪\nSecond line")
        XCTAssertEqual(pinned.revision, 3)
        XCTAssertFalse(pinned.hasRichContent, "Upgrading does not convert any note to rich text.")
        let value2 = try await repository.deletedNotes().map(\.id)
        XCTAssertEqual(value2, [ids.trashedID], "Recently Deleted survives the upgrade.")
    }
}
