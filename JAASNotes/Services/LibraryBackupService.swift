import CoreData
import CryptoKit
import Foundation

/// Why a backup exists. Automatic backups are pruned to a fixed count; the others stay until the user removes them.
enum BackupKind: String, Codable, Equatable, Sendable {
    case automatic
    case manual
    case preRestore
    case preMigration
    /// Taken before permanent deletion. Deletion is refused if this backup cannot be made.
    case preDeletion
}

struct BackupCounts: Codable, Equatable, Sendable {
    let folders: Int
    let activeNotes: Int
    let deletedNotes: Int
}

/// Written last into a backup package. A package without a valid manifest is never listed as a backup.
struct BackupManifest: Codable, Equatable, Sendable {
    static let expectedFormat = "jaasnotes.backup"
    /// Newest manifest format this build can restore. A newer manifest is refused before anything changes.
    static let supportedFormatVersion = 1

    let format: String
    let formatVersion: Int
    let backupID: UUID
    let kind: BackupKind
    let createdAt: Date
    let libraryID: UUID
    /// Library format version the copied store was written with.
    let libraryFormatVersion: Int
    let counts: BackupCounts
    /// Store file name (inside the package's Library folder) to its SHA-256 hex digest.
    let files: [String: String]
    /// Latest modification in the library when the backup was taken. Automatic backups use it to skip unchanged libraries.
    let lastChangeAt: Date?
}

struct BackupSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: BackupKind
    let createdAt: Date
    let counts: BackupCounts
    let url: URL
}

enum LibraryBackupError: Error, Equatable, Sendable {
    case notFound
    case unsupportedBackupFormat(Int)
    case invalidBackup(String)
    case checksumMismatch(String)
    case validationFailed(String)
    case copyFailed(String)
    /// Test-only: an interruption stops the restore without rollback, the way a crash would.
    case simulatedInterruption
}

extension LibraryBackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound:
            "The backup could not be found."
        case .unsupportedBackupFormat:
            "This backup was made by a newer version of JAASNotes, so it cannot be restored. Nothing was changed."
        case .invalidBackup:
            "The backup is incomplete or damaged, so it was not used. Nothing was changed."
        case .checksumMismatch:
            "The backup's contents do not match its checksums, so it was not used. Nothing was changed."
        case .validationFailed:
            "The library could not be checked after the copy, so the copy was not used. Nothing was changed."
        case .copyFailed:
            "The library could not be copied. Check that the disk has space, then try again."
        case .simulatedInterruption:
            "The operation was interrupted."
        }
    }
}

/// Support information written by "Save Diagnostic Info". Contains no note content and no full paths.
struct DiagnosticReport: Codable, Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let libraryFormatVersion: Int
    let backupFormatVersion: Int
    let failure: String?
    let storeFileBytes: [String: Int]
    let backupCount: Int
    let newestBackup: Date?
    let recoveryFolderCount: Int
}

/// Backup packages live beside the library. Layout:
///
///     Backups/<name>/manifest.json
///     Backups/<name>/Library/Store.sqlite (+ -wal / -shm when present)
///
/// A package is built in `Staging/`, validated, and then renamed into `Backups/`, so a partial package never looks valid.
enum LibraryBackupService {
    static let storeFileNames = ["Store.sqlite", "Store.sqlite-wal", "Store.sqlite-shm"]
    static let automaticRetention = 7

    static func backupsDirectory(in location: LibraryLocation) -> URL {
        location.rootURL.appending(path: "Backups", directoryHint: .isDirectory)
    }

    static func stagingDirectory(in location: LibraryLocation) -> URL {
        location.rootURL.appending(path: "Staging", directoryHint: .isDirectory)
    }

    /// Libraries moved aside by restores or by "create new library" are kept here, never deleted.
    static func recoveryDirectory(in location: LibraryLocation) -> URL {
        location.rootURL.appending(path: "Recovery", directoryHint: .isDirectory)
    }

    // MARK: - Creating snapshots

    /// Copies a closed library into a validated backup package. The caller must have closed the live store first.
    /// `legacyModel` is set only for the pre-upgrade snapshot of an earlier library, which the current model cannot open.
    static func createSnapshot(
        of location: LibraryLocation,
        kind: BackupKind,
        now: Date,
        lastChangeAt: Date?,
        legacyModel: NSManagedObjectModel? = nil
    ) async throws -> BackupSummary {
        let fileManager = FileManager.default
        let id = UUID()
        let stagedPackage = stagingDirectory(in: location).appending(path: id.uuidString, directoryHint: .isDirectory)
        let stagedLibrary = stagedPackage.appending(path: "Library", directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: stagedLibrary, withIntermediateDirectories: true)
            try copyStoreFiles(from: location.libraryDirectoryURL, to: stagedLibrary)
            let info: (libraryID: UUID, formatVersion: Int, counts: BackupCounts)
            if let legacyModel {
                info = try LibraryMigrationService.describe(
                    stagedLibrary.appending(path: "Store.sqlite", directoryHint: .notDirectory),
                    model: legacyModel
                )
            } else {
                info = try await validate(LibraryLocation(rootURL: stagedPackage))
            }
            // Checksum the files only after validation. Opening a store can update its -shm and -wal companions.
            // Once checksummed, nothing else opens these files; restores copy them and check the copy.
            let checksums = try checksumStoreFiles(in: stagedLibrary)

            let manifest = BackupManifest(
                format: BackupManifest.expectedFormat,
                formatVersion: BackupManifest.supportedFormatVersion,
                backupID: id,
                kind: kind,
                createdAt: now,
                libraryID: info.libraryID,
                libraryFormatVersion: info.formatVersion,
                counts: info.counts,
                files: checksums,
                lastChangeAt: lastChangeAt
            )
            try write(manifest, to: stagedPackage.appending(path: "manifest.json"))

            let backups = backupsDirectory(in: location)
            try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
            let published = backups.appending(path: directoryName(createdAt: now, id: id), directoryHint: .isDirectory)
            try fileManager.moveItem(at: stagedPackage, to: published)

            return BackupSummary(id: id, kind: kind, createdAt: now, counts: info.counts, url: published)
        } catch {
            // Remove the partial package. The failure that is already being thrown is the one to report.
            try? fileManager.removeItem(at: stagedPackage)
            throw error
        }
    }

    /// Copies the store files that exist, and the attachment payloads. The store file itself is required.
    static func copyStoreFiles(from libraryDirectory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let source = libraryDirectory.appending(path: "Store.sqlite", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: source.path) else {
            throw LibraryBackupError.invalidBackup("The library has no store file.")
        }
        for name in storeFileNames {
            let source = libraryDirectory.appending(path: name, directoryHint: .notDirectory)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            do {
                try fileManager.copyItem(at: source, to: destination.appending(path: name, directoryHint: .notDirectory))
            } catch {
                throw LibraryBackupError.copyFailed(error.localizedDescription)
            }
        }
        let attachments = libraryDirectory.appending(path: AttachmentService.attachmentsFolderName, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: attachments.path) {
            do {
                try fileManager.copyItem(at: attachments, to: destination.appending(path: AttachmentService.attachmentsFolderName, directoryHint: .isDirectory))
            } catch {
                throw LibraryBackupError.copyFailed(error.localizedDescription)
            }
        }
    }

    /// Checksums the store files and every attachment payload. Keys are paths relative to the library folder.
    static func checksumStoreFiles(in libraryDirectory: URL) throws -> [String: String] {
        var checksums: [String: String] = [:]
        for name in storeFileNames {
            let file = libraryDirectory.appending(path: name, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            checksums[name] = try sha256(of: file)
        }
        let attachments = libraryDirectory.appending(path: AttachmentService.attachmentsFolderName, directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in enumerator {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                // The enumerator builds each URL from `attachments`, so its path prefix is exactly that path.
                let relative = AttachmentService.attachmentsFolderName + "/" + String(file.path.dropFirst(attachments.path.count + 1))
                checksums[relative] = try sha256(of: file)
            }
        }
        return checksums
    }

    /// Opens a copy of a library with migration disabled and reads what a restore depends on.
    /// A store that needs migration or has an unknown model fails to open here and is never used.
    static func validate(_ location: LibraryLocation) async throws -> (libraryID: UUID, formatVersion: Int, counts: BackupCounts) {
        let container: NSPersistentContainer
        do {
            container = try await CoreDataStack.openContainer(at: location)
        } catch {
            throw LibraryBackupError.validationFailed(error.localizedDescription)
        }
        let repository = LibraryRepository(container: container)
        let info: (libraryID: UUID, formatVersion: Int, counts: BackupCounts)
        do {
            guard let metadata = try await repository.libraryMetadata() else {
                throw LibraryBackupError.validationFailed("The library has no metadata record.")
            }
            guard metadata.formatVersion <= LibraryRepository.currentFormatVersion else {
                throw LibraryBackupError.unsupportedBackupFormat(metadata.formatVersion)
            }
            let folders = try await repository.folders()
            guard folders.filter(\.isDefault).count == 1 else {
                throw LibraryBackupError.validationFailed("The library does not have exactly one default folder.")
            }
            try AttachmentService.verifyPayloads(try await repository.allAttachments(), in: location.libraryDirectoryURL)
            let active = try await repository.activeNotes(inFolder: nil)
            let deleted = try await repository.deletedNotes()
            info = (
                metadata.libraryID,
                metadata.formatVersion,
                BackupCounts(folders: folders.count, activeNotes: active.count, deletedNotes: deleted.count)
            )
        } catch {
            try? CoreDataStack.close(container)
            throw error
        }
        try CoreDataStack.close(container)
        return info
    }

    /// Moves the library folder aside into Recovery and returns where it went. Nil when there was no library.
    /// Nothing is deleted.
    static func moveLibraryAside(_ location: LibraryLocation) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: location.libraryDirectoryURL.path) else { return nil }
        let destination = recoveryDirectory(in: location)
            .appending(path: "library-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: location.libraryDirectoryURL, to: destination)
        return destination
    }

    /// Sanitized JSON for support: app and format versions, store file names and sizes, and backup counts.
    /// It never contains note text, titles, or full paths.
    static func diagnosticReport(of location: LibraryLocation, failure: String?, now: Date) throws -> Data {
        let fileManager = FileManager.default
        var storeFiles: [String: Int] = [:]
        for name in storeFileNames {
            let url = location.libraryDirectoryURL.appending(path: name, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: url.path) {
                let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
                storeFiles[name] = size
            }
        }
        let backups = try list(in: location)
        let recoveryCount = try recoveryFolderCount(in: location)
        let report = DiagnosticReport(
            generatedAt: now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            libraryFormatVersion: LibraryRepository.currentFormatVersion,
            backupFormatVersion: BackupManifest.supportedFormatVersion,
            failure: failure,
            storeFileBytes: storeFiles,
            backupCount: backups.count,
            newestBackup: backups.first?.createdAt,
            recoveryFolderCount: recoveryCount
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private static func recoveryFolderCount(in location: LibraryLocation) throws -> Int {
        let folder = recoveryDirectory(in: location)
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).count
    }

    /// Keeps the newest automatic backups and removes the rest. Manual and pre-restore backups are never pruned.
    /// Call only after a new backup has been validated and published.
    static func pruneAutomaticBackups(in location: LibraryLocation, keeping count: Int = automaticRetention) throws {
        let automatic = try list(in: location).filter { $0.kind == .automatic }
        for old in automatic.dropFirst(count) {
            try FileManager.default.removeItem(at: old.url)
        }
    }

    // MARK: - Listing and reading

    /// Valid backup packages, newest first. Packages whose manifest is missing or unreadable are skipped.
    static func list(in location: LibraryLocation) throws -> [BackupSummary] {
        let fileManager = FileManager.default
        let directory = backupsDirectory(in: location)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries.compactMap { entry -> BackupSummary? in
            guard let manifest = try? readManifest(in: entry) else { return nil }
            return BackupSummary(
                id: manifest.backupID,
                kind: manifest.kind,
                createdAt: manifest.createdAt,
                counts: manifest.counts,
                url: entry
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func readManifest(in package: URL) throws -> BackupManifest {
        let data = try Data(contentsOf: package.appending(path: "manifest.json", directoryHint: .notDirectory))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: data)
        guard manifest.format == BackupManifest.expectedFormat else {
            throw LibraryBackupError.invalidBackup("Unexpected backup format.")
        }
        guard manifest.formatVersion <= BackupManifest.supportedFormatVersion else {
            throw LibraryBackupError.unsupportedBackupFormat(manifest.formatVersion)
        }
        return manifest
    }

    /// Checks every store file in a package against its manifest checksum.
    static func verifyChecksums(of manifest: BackupManifest, in package: URL) throws {
        for (name, expected) in manifest.files {
            let file = package.appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .notDirectory)
            guard try sha256(of: file) == expected else {
                throw LibraryBackupError.checksumMismatch(name)
            }
        }
    }

    // MARK: - Helpers

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        try handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ manifest: BackupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    /// Sortable, unique, and free of characters that are awkward in paths.
    private static func directoryName(createdAt: Date, id: UUID) -> String {
        let stamp = createdAt.formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
        ).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(id.uuidString.prefix(8))"
    }
}
