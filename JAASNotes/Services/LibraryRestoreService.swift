import Foundation

/// Restores a backup with a recoverable swap. The current library is moved aside, never deleted, and is put back if
/// the replacement cannot be opened and validated. A transaction marker lets startup finish or undo a restore that was
/// interrupted, so a crash between the two renames cannot leave the library missing.
enum LibraryRestoreService {
    /// Test-only points where a restore is stopped as if the app had crashed.
    enum InterruptionPoint: Sendable {
        case afterMovingLibraryAside
        case afterInstallingBackup
    }

    private struct Transaction: Codable {
        /// Where the previous library was moved, relative to the library root. Nil when no library existed.
        let previousLibrary: String?
        /// The validated replacement, relative to the library root.
        let candidate: String
    }

    private static func transactionURL(_ location: LibraryLocation) -> URL {
        LibraryBackupService.stagingDirectory(in: location)
            .appending(path: "restore-transaction.json", directoryHint: .notDirectory)
    }

    /// Replaces the library at `location` with `backup`. The caller must have closed any open store for `location`.
    /// Works for an empty location too, which restores into a fresh library. A version-1 backup is migrated in staging
    /// before it is checked, so it can be restored into this version.
    static func restore(
        _ backup: BackupSummary,
        into location: LibraryLocation,
        interruptAt interruption: InterruptionPoint? = nil
    ) async throws {
        let fileManager = FileManager.default

        // Refuse unknown or damaged backups before anything in the library changes.
        let manifest = try LibraryBackupService.readManifest(in: backup.url)
        try LibraryBackupService.verifyChecksums(of: manifest, in: backup.url)

        let operationID = UUID().uuidString
        let stagingFolder = LibraryBackupService.stagingDirectory(in: location)
            .appending(path: "restore-\(operationID)", directoryHint: .isDirectory)

        // Copy the backup into staging and validate that copy. The live library is not touched yet.
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(
                at: backup.url.appending(path: "Library", directoryHint: .isDirectory),
                to: stagingFolder.appending(path: "Library", directoryHint: .isDirectory)
            )
            let staged = LibraryLocation(rootURL: stagingFolder)
            _ = try await LibraryMigrationService.migrateIfNeeded(staged, takeBackup: false)
            _ = try await LibraryBackupService.validate(staged)
        } catch {
            try? fileManager.removeItem(at: stagingFolder)
            throw error
        }

        try await install(stagingFolder: stagingFolder, into: location, interruptAt: interruption)
    }

    /// Swaps a validated candidate in for the library at `location`. `stagingFolder` holds the candidate as `Library/`.
    /// The current library is moved aside, never deleted. A failure rolls back; an interruption leaves the marker in
    /// place for `recoverInterruptedRestore`.
    static func install(
        stagingFolder: URL,
        into location: LibraryLocation,
        interruptAt interruption: InterruptionPoint? = nil
    ) async throws {
        let fileManager = FileManager.default
        let candidateLibrary = stagingFolder.appending(path: "Library", directoryHint: .isDirectory)
        let operationID = stagingFolder.lastPathComponent

        // Record the plan before the first rename, so an interruption can be recovered at startup.
        let libraryURL = location.libraryDirectoryURL
        let hadLibrary = fileManager.fileExists(atPath: libraryURL.path)
        let transaction = Transaction(
            previousLibrary: hadLibrary ? "Recovery/\(operationID)/Library" : nil,
            candidate: "Staging/\(operationID)/Library"
        )
        try write(transaction, to: transactionURL(location))

        var previousMoved = false
        var candidateInstalled = false
        do {
            if let previous = transaction.previousLibrary {
                let previousURL = location.rootURL.appending(path: previous, directoryHint: .isDirectory)
                try fileManager.createDirectory(
                    at: previousURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: libraryURL, to: previousURL)
                previousMoved = true
            }
            if interruption == .afterMovingLibraryAside {
                throw LibraryBackupError.simulatedInterruption
            }

            try fileManager.moveItem(at: candidateLibrary, to: libraryURL)
            candidateInstalled = true
            if interruption == .afterInstallingBackup {
                throw LibraryBackupError.simulatedInterruption
            }

            _ = try await LibraryBackupService.validate(location)
        } catch LibraryBackupError.simulatedInterruption {
            // Leave the marker and every directory in place, as a crash would. Startup recovery finishes the job.
            throw LibraryBackupError.simulatedInterruption
        } catch {
            try rollBack(location, transaction: transaction, candidateInstalled: candidateInstalled, previousMoved: previousMoved)
            try? fileManager.removeItem(at: stagingFolder)
            throw error
        }

        try fileManager.removeItem(at: transactionURL(location))
        try? fileManager.removeItem(at: stagingFolder)
    }

    /// Finishes or undoes a restore that did not complete. Call before opening the library at `location`.
    /// Does nothing when no transaction is pending.
    static func recoverInterruptedRestore(at location: LibraryLocation) async throws {
        let fileManager = FileManager.default
        let marker = transactionURL(location)
        guard fileManager.fileExists(atPath: marker.path) else { return }

        let transaction = try read(marker)
        let libraryURL = location.libraryDirectoryURL
        let previousURL = transaction.previousLibrary.map { location.rootURL.appending(path: $0, directoryHint: .isDirectory) }
        let candidateURL = location.rootURL.appending(path: transaction.candidate, directoryHint: .isDirectory)

        if fileManager.fileExists(atPath: libraryURL.path) {
            // Either the replacement is installed, or the restore never got that far and this is the original.
            // Keep whichever opens. Put the previous library back only when the installed copy does not open.
            do {
                _ = try await LibraryBackupService.validate(location)
            } catch {
                guard let previousURL, fileManager.fileExists(atPath: previousURL.path) else {
                    throw error
                }
                try fileManager.removeItem(at: libraryURL)
                try fileManager.moveItem(at: previousURL, to: libraryURL)
            }
        } else if let previousURL, fileManager.fileExists(atPath: previousURL.path) {
            // The previous library was moved aside, but the replacement was never installed. Put it back.
            try fileManager.moveItem(at: previousURL, to: libraryURL)
        } else if fileManager.fileExists(atPath: candidateURL.path) {
            // Nothing was moved aside yet, and the replacement is still staged. Install it and validate it.
            try fileManager.moveItem(at: candidateURL, to: libraryURL)
            do {
                _ = try await LibraryBackupService.validate(location)
            } catch {
                try fileManager.removeItem(at: libraryURL)
                throw error
            }
        }

        try fileManager.removeItem(at: marker)
        let stagingFolder = candidateURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: stagingFolder.path) {
            try fileManager.removeItem(at: stagingFolder)
        }
    }

    private static func rollBack(
        _ location: LibraryLocation,
        transaction: Transaction,
        candidateInstalled: Bool,
        previousMoved: Bool
    ) throws {
        let fileManager = FileManager.default
        let libraryURL = location.libraryDirectoryURL
        // Only the installed replacement is removed. A library that was never moved is the user's and stays.
        if candidateInstalled, fileManager.fileExists(atPath: libraryURL.path) {
            try fileManager.removeItem(at: libraryURL)
        }
        if previousMoved, let previous = transaction.previousLibrary {
            let previousURL = location.rootURL.appending(path: previous, directoryHint: .isDirectory)
            try fileManager.moveItem(at: previousURL, to: libraryURL)
        }
        try fileManager.removeItem(at: transactionURL(location))
    }

    private static func write(_ transaction: Transaction, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(transaction).write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) throws -> Transaction {
        try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: url))
    }
}
