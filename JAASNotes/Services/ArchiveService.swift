import AppKit
import CryptoKit
import Foundation

/// A portable JAASNotes archive: a folder with a manifest, the folders and notes as JSON, and each attachment's bytes.
/// It is separate from the Core Data backups. Import always creates new identities and never overwrites a note.
///
/// Layout (format version 1):
/// ```text
/// manifest.json                      format, version, counts, and a SHA-256 for every other file
/// archive.json                       folders, notes, rich text (base64 RTF), checklists, attachment metadata
/// attachments/<UUID>/payload         the attachment's bytes
/// ```
enum ArchiveService {
    static let formatName = "jaasnotes-archive"
    static let formatVersion = 1
    static let documentPath = "archive.json"
    static let manifestPath = "manifest.json"
    /// Provisional per-file limits for archive contents. Anything larger is refused before it is copied.
    static let maximumDocumentBytes: Int64 = 64 * 1024 * 1024
    static let maximumAttachmentBytes = AttachmentService.defaultMaximumBytes

    // MARK: - Format

    struct Manifest: Codable, Equatable, Sendable {
        let format: String
        let formatVersion: Int
        let createdAt: Date
        let counts: Counts
        /// SHA-256 of every file in the archive except this manifest.
        let files: [String: String]
    }

    struct Counts: Codable, Equatable, Sendable {
        let folders: Int
        let notes: Int
        let attachments: Int
    }

    struct Document: Codable, Equatable, Sendable {
        let folders: [ArchivedFolder]
        let notes: [ArchivedNote]
    }

    struct ArchivedFolder: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        let createdAt: Date
        let modifiedAt: Date
        let isDefault: Bool
    }

    struct ArchivedNote: Codable, Equatable, Sendable {
        let id: UUID
        let folderID: UUID
        let title: String
        let bodyPlainText: String
        let createdAt: Date
        let modifiedAt: Date
        let deletedAt: Date?
        let isPinned: Bool
        /// Base64 of the note's RTF, or nil for plain text.
        let rtf: Data?
        let checklist: ChecklistSidecar?
        let attachments: [ArchivedAttachment]
    }

    struct ArchivedAttachment: Codable, Equatable, Sendable {
        let id: UUID
        let originalFilename: String
        let contentType: String
        let byteCount: Int64
        let sha256: String
        /// Relative to the archive folder, for example `attachments/<UUID>/payload`.
        let path: String
    }

    // MARK: - Exporting

    /// Writes a new archive folder at `destination`. Attachments are checked against their recorded checksums first.
    /// Nothing is written at `destination` unless every note and file was read.
    static func export(to destination: URL, store: NoteStore, location: LibraryLocation, now: Date = Date()) async throws -> Counts {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ArchiveError.destinationExists
        }
        let folders = try await store.folders()
        let notes = try await store.activeNotes(inFolder: nil) + store.deletedNotes()

        var archivedNotes: [ArchivedNote] = []
        var payloads: [(source: URL, path: String)] = []
        for note in notes {
            let body = try await store.body(of: note.id)
            let attachments = try await store.attachments(forNote: note.id)
            var archived: [ArchivedAttachment] = []
            for attachment in attachments {
                guard AttachmentService.isSafeRelativePath(attachment.relativePath) else {
                    throw ArchiveError.exportFailed("An attachment has an unsafe stored location.")
                }
                let source = location.libraryDirectoryURL.appending(path: attachment.relativePath, directoryHint: .notDirectory)
                guard try LibraryBackupService.sha256(of: source) == attachment.sha256 else {
                    throw ArchiveError.exportFailed("An attachment does not match its checksum, so the archive was not written.")
                }
                let path = "attachments/\(attachment.id.uuidString)/payload"
                payloads.append((source, path))
                archived.append(ArchivedAttachment(
                    id: attachment.id,
                    originalFilename: attachment.originalFilename,
                    contentType: attachment.contentType,
                    byteCount: attachment.byteCount,
                    sha256: attachment.sha256,
                    path: path
                ))
            }

            let (rtf, checklist, plain): (Data?, ChecklistSidecar?, String)
            switch body {
            case .rich(let content):
                (rtf, checklist, plain) = (content.rtf, content.checklist, content.plainText)
            case .plain(let text):
                (rtf, checklist, plain) = (nil, nil, text)
            case .unreadable(let fallback, _):
                // The formatting cannot be read, so the archive carries the saved text only.
                (rtf, checklist, plain) = (nil, nil, fallback)
            }
            archivedNotes.append(ArchivedNote(
                id: note.id,
                folderID: note.folderID,
                title: note.title,
                bodyPlainText: plain,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                deletedAt: note.deletedAt,
                isPinned: note.isPinned,
                rtf: rtf,
                checklist: checklist,
                attachments: archived
            ))
        }

        let document = Document(
            folders: folders.map {
                ArchivedFolder(id: $0.id, name: $0.name, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt, isDefault: $0.isDefault)
            },
            notes: archivedNotes
        )
        let documentData = try encoder().encode(document)

        // Build in a staging folder, then move the finished folder into place, so a failed export leaves nothing at `destination`.
        let staging = LibraryBackupService.stagingDirectory(in: location)
            .appending(path: "archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try documentData.write(to: staging.appending(path: documentPath, directoryHint: .notDirectory))

        var checksums: [String: String] = [documentPath: sha256Hex(documentData)]
        for payload in payloads {
            let target = staging.appending(path: payload.path, directoryHint: .notDirectory)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: payload.source, to: target)
            checksums[payload.path] = try LibraryBackupService.sha256(of: target)
        }

        let counts = Counts(folders: folders.count, notes: archivedNotes.count, attachments: payloads.count)
        let manifest = Manifest(format: formatName, formatVersion: formatVersion, createdAt: now, counts: counts, files: checksums)
        try encoder().encode(manifest).write(to: staging.appending(path: manifestPath, directoryHint: .notDirectory))

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: destination)
        return counts
    }

    // MARK: - Reading and checking

    /// An archive that has passed every check. Nothing in the library has changed yet.
    struct Validated: Sendable {
        let packageURL: URL
        let manifest: Manifest
        let document: Document
        /// Final names for each archived folder, avoiding names already in the library.
        let folderNames: [UUID: String]
        /// Folders renamed to avoid a clash, for the user to review before importing.
        let renamedFolders: [Rename]

        struct Rename: Equatable, Sendable {
            let original: String
            let final: String
        }
    }

    /// Checks an archive folder completely. Refuses unknown formats and versions, unexpected or unsafe files, checksum
    /// mismatches, oversized files, and any note whose rich text or checklist does not validate.
    static func read(at package: URL, existingFolderNames: [String]) throws -> Validated {
        let fileManager = FileManager.default
        let manifestURL = package.appending(path: manifestPath, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw ArchiveError.notAnArchive }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw ArchiveError.notAnArchive
        }
        guard manifest.format == formatName else { throw ArchiveError.notAnArchive }
        guard manifest.formatVersion == formatVersion else { throw ArchiveError.unsupportedVersion(manifest.formatVersion) }

        // Every file must be listed, match its checksum, and sit at a path the format allows.
        let present = try listedFiles(in: package)
        for path in present where path != manifestPath && manifest.files[path] == nil {
            throw ArchiveError.unexpectedFile
        }
        for (path, expected) in manifest.files {
            guard isAllowedPath(path) else { throw ArchiveError.unsafePath }
            guard present.contains(path) else { throw ArchiveError.missingFile }
            let file = package.appending(path: path, directoryHint: .notDirectory)
            let limit = path == documentPath ? maximumDocumentBytes : maximumAttachmentBytes
            if let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, size > limit {
                throw ArchiveError.tooLarge
            }
            guard try LibraryBackupService.sha256(of: file) == expected else { throw ArchiveError.checksumMismatch }
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: package.appending(path: documentPath, directoryHint: .notDirectory)))
        } catch {
            throw ArchiveError.invalidContent
        }
        try validate(document, manifest: manifest)

        let (names, renames) = finalFolderNames(for: document.folders, existing: existingFolderNames)
        return Validated(packageURL: package, manifest: manifest, document: document, folderNames: names, renamedFolders: renames)
    }

    private static func validate(_ document: Document, manifest: Manifest) throws {
        guard manifest.counts.folders == document.folders.count,
              manifest.counts.notes == document.notes.count,
              manifest.counts.attachments == document.notes.reduce(0, { $0 + $1.attachments.count })
        else {
            throw ArchiveError.invalidContent
        }
        let folderIDs = Set(document.folders.map(\.id))
        guard folderIDs.count == document.folders.count else { throw ArchiveError.invalidContent }
        let noteIDs = Set(document.notes.map(\.id))
        guard noteIDs.count == document.notes.count else { throw ArchiveError.invalidContent }

        var attachmentIDs = Set<UUID>()
        for note in document.notes {
            guard folderIDs.contains(note.folderID) else { throw ArchiveError.invalidContent }
            // Rich text and checklists must read back exactly as they were written.
            if let rtf = note.rtf {
                let content = try RichTextCodec.content(rtf: rtf, checklistData: try note.checklist.map(RichTextCodec.encodeChecklist))
                guard content.plainText == note.bodyPlainText else { throw ArchiveError.invalidContent }
            } else {
                guard note.checklist == nil else { throw ArchiveError.invalidContent }
            }
            for attachment in note.attachments {
                guard attachmentIDs.insert(attachment.id).inserted else { throw ArchiveError.invalidContent }
                guard attachment.path == "attachments/\(attachment.id.uuidString)/payload",
                      manifest.files[attachment.path] == attachment.sha256
                else {
                    throw ArchiveError.invalidContent
                }
            }
        }
    }

    /// Names for archived folders. A name that is already used in the library gets " (Imported)", then " (Imported 2)", and so on.
    /// Folders from the archive's default Notes folder are imported as a new folder, never merged into the library's Notes.
    static func finalFolderNames(for folders: [ArchivedFolder], existing: [String]) -> (names: [UUID: String], renames: [Validated.Rename]) {
        var taken = Set(existing.map(FolderName.normalize))
        var names: [UUID: String] = [:]
        var renames: [Validated.Rename] = []
        for folder in folders {
            var name = folder.name
            if folder.isDefault || taken.contains(FolderName.normalize(name)) {
                var candidate = "\(folder.name) (Imported)"
                var suffix = 1
                while taken.contains(FolderName.normalize(candidate)) {
                    suffix += 1
                    candidate = "\(folder.name) (Imported \(suffix))"
                }
                name = candidate
                renames.append(Validated.Rename(original: folder.name, final: name))
            }
            taken.insert(FolderName.normalize(name))
            names[folder.id] = name
        }
        return (names, renames)
    }

    // MARK: - Importing

    /// Copies the archive's attachment bytes into the library, then records everything in one transaction.
    /// If the transaction fails, the copied bytes are removed. A crash before the transaction leaves bytes with no
    /// rows, which reconciliation moves to Recovery at the next launch.
    static func importArchive(_ archive: Validated, location: LibraryLocation, store: NoteStore) async throws -> Counts {
        let fileManager = FileManager.default
        var movedFolders: [URL] = []
        var newAttachments: [NewAttachment] = []

        do {
            for note in archive.document.notes {
                for attachment in note.attachments {
                    let newID = UUID()
                    let folder = AttachmentService.attachmentsDirectory(in: location)
                        .appending(path: newID.uuidString, directoryHint: .isDirectory)
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    movedFolders.append(folder)
                    let source = archive.packageURL.appending(path: attachment.path, directoryHint: .notDirectory)
                    try fileManager.copyItem(at: source, to: folder.appending(path: "payload", directoryHint: .notDirectory))
                    newAttachments.append(NewAttachment(
                        id: newID,
                        noteID: note.id,
                        originalFilename: attachment.originalFilename,
                        contentType: attachment.contentType,
                        byteCount: attachment.byteCount,
                        sha256: attachment.sha256,
                        relativePath: "\(AttachmentService.attachmentsFolderName)/\(newID.uuidString)/payload"
                    ))
                }
            }

            let plan = try makePlan(archive, attachments: newAttachments)
            try await store.importArchive(plan)
        } catch {
            for folder in movedFolders {
                try? fileManager.removeItem(at: folder)
            }
            throw error
        }
        return archive.manifest.counts
    }

    /// Builds the import from the validated archive: every folder and note gets a new identity, and every note keeps its
    /// own dates, pin, trash state, formatting, and checklist.
    private static func makePlan(_ archive: Validated, attachments: [NewAttachment]) throws -> ArchiveImportPlan {
        var newFolderIDs: [UUID: UUID] = [:]
        let folders = archive.document.folders.map { folder -> ArchiveImportPlan.Folder in
            let id = UUID()
            newFolderIDs[folder.id] = id
            return ArchiveImportPlan.Folder(id: id, name: archive.folderNames[folder.id] ?? folder.name, createdAt: folder.createdAt, modifiedAt: folder.modifiedAt)
        }
        let notes = try archive.document.notes.map { note -> ArchiveImportPlan.Note in
            guard let folderID = newFolderIDs[note.folderID] else { throw ArchiveError.invalidContent }
            return ArchiveImportPlan.Note(
                id: UUID(),
                folderID: folderID,
                title: note.title,
                bodyPlainText: note.bodyPlainText,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                deletedAt: note.deletedAt,
                isPinned: note.isPinned,
                rtf: note.rtf,
                checklistData: try note.checklist.map(RichTextCodec.encodeChecklist)
            )
        }
        // Attachments must point at the new note IDs, so they are re-keyed here.
        var newNoteIDs: [UUID: UUID] = [:]
        for (archived, planned) in zip(archive.document.notes, notes) {
            newNoteIDs[archived.id] = planned.id
        }
        let rekeyed = attachments.map { attachment -> NewAttachment in
            NewAttachment(
                id: attachment.id,
                noteID: newNoteIDs[attachment.noteID] ?? attachment.noteID,
                originalFilename: attachment.originalFilename,
                contentType: attachment.contentType,
                byteCount: attachment.byteCount,
                sha256: attachment.sha256,
                relativePath: attachment.relativePath
            )
        }
        return ArchiveImportPlan(folders: folders, notes: notes, attachments: rekeyed)
    }

    // MARK: - Single notes as text

    /// Plain text for one note: its title on the first line, then the text. Formatting is not kept.
    static func plainTextExport(title: String, body: String) -> Data {
        let heading = title.isEmpty ? "" : title + "\n\n"
        return Data((heading + body).utf8)
    }

    /// RTF for one note. Rich notes keep their formatting; plain notes become unformatted RTF.
    static func rtfExport(title: String, body: NoteBody) throws -> Data {
        let text: NSAttributedString
        switch body {
        case .rich(let content):
            text = try RichTextCodec.attributedString(of: content)
        case .plain(let plain), .unreadable(let plain, _):
            text = NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        }
        let combined = NSMutableAttributedString(string: title.isEmpty ? "" : title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        combined.append(text)
        do {
            return try combined.data(from: NSRange(location: 0, length: combined.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } catch {
            throw ArchiveError.exportFailed("The note could not be written as RTF.")
        }
    }

    /// Reads a plain text file as one note. Text must be valid UTF-8, and the title comes from the file name.
    static func importPlainText(at url: URL) throws -> (title: String, body: String) {
        guard let body = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw ArchiveError.notReadableText
        }
        guard body.utf8.count <= maximumDocumentBytes else { throw ArchiveError.tooLarge }
        return (url.deletingPathExtension().lastPathComponent, body)
    }

    /// Reads an RTF file as one rich note. The RTF is validated like any other rich body.
    static func importRTF(at url: URL) throws -> (title: String, content: RichNoteContent) {
        let data = try Data(contentsOf: url)
        guard data.count <= RichTextCodec.maximumRTFBytes else { throw ArchiveError.tooLarge }
        let content: RichNoteContent
        do {
            let text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            content = try RichTextCodec.content(from: text, checklist: nil)
        } catch {
            throw ArchiveError.notReadableText
        }
        return (url.deletingPathExtension().lastPathComponent, content)
    }

    // MARK: - Helpers

    private static func isAllowedPath(_ path: String) -> Bool {
        if path == documentPath { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "attachments" && parts[2] == "payload" && UUID(uuidString: String(parts[1])) != nil
    }

    /// Every regular file under the package, relative to it. Symbolic links and folders other than the required ones are refused.
    private static func listedFiles(in package: URL) throws -> Set<String> {
        var files = Set<String>()
        let root = package.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: package,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        ) else {
            throw ArchiveError.notAnArchive
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { throw ArchiveError.unsafePath }
            guard values.isRegularFile == true else { continue }
            let standardized = url.standardizedFileURL.path
            files.insert(String(standardized.dropFirst(root.count + 1)))
        }
        return files
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What an import will write. Built only from a validated archive, and written in one transaction.
struct ArchiveImportPlan: Sendable {
    struct Folder: Sendable {
        let id: UUID
        let name: String
        let createdAt: Date
        let modifiedAt: Date
    }

    struct Note: Sendable {
        let id: UUID
        let folderID: UUID
        let title: String
        let bodyPlainText: String
        let createdAt: Date
        let modifiedAt: Date
        let deletedAt: Date?
        let isPinned: Bool
        let rtf: Data?
        let checklistData: Data?
    }

    let folders: [Folder]
    let notes: [Note]
    let attachments: [NewAttachment]
}

/// Why an archive or text file was refused. Messages never include note text or file paths.
enum ArchiveError: Error, Equatable, Sendable {
    case notAnArchive
    case unsupportedVersion(Int)
    case missingFile
    case unexpectedFile
    case unsafePath
    case checksumMismatch
    case tooLarge
    case invalidContent
    case destinationExists
    case notReadableText
    case exportFailed(String)
}

extension ArchiveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            "This is not a JAASNotes archive."
        case .unsupportedVersion(let version):
            "This archive uses format \(version), which this version of JAASNotes cannot read."
        case .missingFile:
            "The archive is missing a file it lists, so nothing was imported."
        case .unexpectedFile:
            "The archive contains a file it does not list, so nothing was imported."
        case .unsafePath:
            "The archive contains a path that is not allowed, so nothing was imported."
        case .checksumMismatch:
            "A file in the archive does not match its checksum, so nothing was imported."
        case .tooLarge:
            "A file in the archive is larger than allowed, so nothing was imported."
        case .invalidContent:
            "The archive's contents do not check out, so nothing was imported."
        case .destinationExists:
            "That location already has an item with the same name. Choose another name."
        case .notReadableText:
            "This file could not be read as text, so nothing was imported."
        case .exportFailed(let detail):
            "The export did not finish. \(detail)"
        }
    }
}
