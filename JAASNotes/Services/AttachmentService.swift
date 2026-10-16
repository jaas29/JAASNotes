import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The repository operations attachments need. `LibraryRepository` implements them; tests wrap them to inject failures.
protocol AttachmentStore: Sendable {
    func createAttachment(_ new: NewAttachment) async throws -> AttachmentSnapshot
    func deleteAttachment(id: UUID) async throws
    func attachments(forNote noteID: UUID) async throws -> [AttachmentSnapshot]
    func allAttachments() async throws -> [AttachmentSnapshot]
}

/// Why an attachment was refused. Messages never include file names or paths.
enum AttachmentError: Error, Equatable, Sendable {
    case tooLarge(limit: Int64)
    case notARegularFile
    case unreadable
    case unsafePath
}

extension AttachmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "This file is larger than the 100 MB limit, so it was not attached."
        case .notARegularFile:
            "Only ordinary files can be attached. Links and folders cannot."
        case .unreadable:
            "The file could not be read, so it was not attached."
        case .unsafePath:
            "An attachment's stored location is not valid, so it was not used."
        }
    }
}

/// Copies files into the library and keeps their bytes and rows in agreement.
///
/// Import order: the bytes are copied into staging while being hashed and size-checked, flushed to disk, and moved to an
/// immutable location in the library. Only then is the row committed. A row therefore never points at bytes that were
/// not written. A failed commit removes the moved bytes. A crash can leave bytes with no row; `reconcile` moves those to Recovery.
enum AttachmentService {
    /// Provisional per-file limit from the plan. Checked before copying, and again while copying in case the file grows.
    static let defaultMaximumBytes: Int64 = 100 * 1024 * 1024

    /// Test-only: stop after the payload is in place and before the row is committed, as a crash would.
    enum Fault: Sendable {
        case afterPayloadMoved
    }

    /// Result of a reconciliation pass.
    struct Reconciliation: Equatable, Sendable {
        /// Attachments whose file is missing or the wrong size. Their rows are kept; nothing is deleted.
        let damagedAttachmentIDs: [UUID]
        /// Payload folders with no row. They were moved into Recovery, not deleted.
        let quarantinedFolderNames: [String]
    }

    static let attachmentsFolderName = "Attachments"

    static func attachmentsDirectory(in location: LibraryLocation) -> URL {
        location.libraryDirectoryURL.appending(path: attachmentsFolderName, directoryHint: .isDirectory)
    }

    /// Copies `source` into the library and records it as an attachment of `noteID`.
    static func importFile(
        at source: URL,
        noteID: UUID,
        location: LibraryLocation,
        store: AttachmentStore,
        maximumBytes: Int64 = defaultMaximumBytes,
        fault: Fault? = nil
    ) async throws -> AttachmentSnapshot {
        let fileManager = FileManager.default
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw AttachmentError.unreadable
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw AttachmentError.notARegularFile
        }
        if let size = values.fileSize, Int64(size) > maximumBytes {
            throw AttachmentError.tooLarge(limit: maximumBytes)
        }

        let id = UUID()
        let staging = LibraryBackupService.stagingDirectory(in: location)
            .appending(path: "attachment-\(id.uuidString)", directoryHint: .isDirectory)
        let partial = staging.appending(path: "payload", directoryHint: .notDirectory)
        let folder = attachmentsDirectory(in: location).appending(path: id.uuidString, directoryHint: .isDirectory)
        let relativePath = "\(attachmentsFolderName)/\(id.uuidString)/payload"
        var payloadMoved = false

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let copied = try copyAndHash(from: source, to: partial, maximumBytes: maximumBytes)

            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: partial, to: folder.appending(path: "payload", directoryHint: .notDirectory))
            payloadMoved = true
            if fault == .afterPayloadMoved {
                throw LibraryBackupError.simulatedInterruption
            }

            let snapshot = try await store.createAttachment(NewAttachment(
                id: id,
                noteID: noteID,
                originalFilename: source.lastPathComponent,
                contentType: contentType(forExtension: source.pathExtension),
                byteCount: copied.byteCount,
                sha256: copied.sha256,
                relativePath: relativePath
            ))
            try? fileManager.removeItem(at: staging)
            return snapshot
        } catch LibraryBackupError.simulatedInterruption {
            // Leave the moved bytes in place, as a crash would. Reconciliation finds them later.
            try? fileManager.removeItem(at: staging)
            throw LibraryBackupError.simulatedInterruption
        } catch {
            if payloadMoved {
                try? fileManager.removeItem(at: folder)
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Removes the payload folders of attachments whose rows were deleted. Best effort: reconciliation catches any leftovers.
    static func removePayloads(of attachmentIDs: [UUID], location: LibraryLocation) {
        for id in attachmentIDs {
            let folder = attachmentsDirectory(in: location).appending(path: id.uuidString, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Checks that every row has a payload of the right size, and moves payload folders without rows into Recovery.
    /// Damaged rows are reported, never deleted.
    static func reconcile(location: LibraryLocation, store: AttachmentStore, now: Date = Date()) async throws -> Reconciliation {
        let fileManager = FileManager.default
        let rows = try await store.allAttachments()

        var damaged: [UUID] = []
        for row in rows {
            guard isSafeRelativePath(row.relativePath) else {
                damaged.append(row.id)
                continue
            }
            let url = location.libraryDirectoryURL.appending(path: row.relativePath, directoryHint: .notDirectory)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            if size != row.byteCount {
                damaged.append(row.id)
            }
        }

        let known = Set(rows.map { $0.id.uuidString })
        var quarantined: [String] = []
        let root = attachmentsDirectory(in: location)
        let folders = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in folders where !known.contains(name) {
            let destination = LibraryBackupService.recoveryDirectory(in: location)
                .appending(path: "orphaned-attachments", directoryHint: .isDirectory)
                .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: root.appending(path: name, directoryHint: .isDirectory), to: destination)
            quarantined.append(name)
        }
        return Reconciliation(damagedAttachmentIDs: damaged, quarantinedFolderNames: quarantined)
    }

    /// Verifies the payload of every attachment in a closed or staged library: present, the right size, and the
    /// recorded SHA-256. Used before a backup is published and before a restore is accepted.
    static func verifyPayloads(_ rows: [AttachmentSnapshot], in libraryDirectory: URL) throws {
        for row in rows {
            guard isSafeRelativePath(row.relativePath) else {
                throw LibraryBackupError.validationFailed("An attachment has an unsafe stored location.")
            }
            let url = libraryDirectory.appending(path: row.relativePath, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LibraryBackupError.validationFailed("An attachment's file is missing.")
            }
            guard try LibraryBackupService.sha256(of: url) == row.sha256 else {
                throw LibraryBackupError.validationFailed("An attachment does not match its checksum.")
            }
        }
    }

    /// Only `Attachments/<UUID>/payload` is ever a valid stored location. Absolute paths and `..` are refused.
    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == attachmentsFolderName, parts[2] == "payload",
              UUID(uuidString: String(parts[1])) != nil
        else {
            return false
        }
        return true
    }

    // MARK: - Helpers

    private static func copyAndHash(from source: URL, to destination: URL, maximumBytes: Int64) throws -> (byteCount: Int64, sha256: String) {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw AttachmentError.unreadable
        }
        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw AttachmentError.unreadable
        }
        defer {
            try? input.close()
            try? output.close()
        }

        var hasher = SHA256()
        var total: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                total += Int64(chunk.count)
                guard total <= maximumBytes else {
                    throw AttachmentError.tooLarge(limit: maximumBytes)
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch let error as AttachmentError {
            throw error
        } catch {
            throw AttachmentError.unreadable
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// The content type from the file extension, or a generic type. Never executed or trusted for anything but display.
    static func contentType(forExtension ext: String) -> String {
        guard !ext.isEmpty else { return "application/octet-stream" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
