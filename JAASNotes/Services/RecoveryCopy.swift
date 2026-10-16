import Foundation

/// One note's unsaved text, plus the stored revision it was edited from.
struct RecoveryDraft: Codable, Equatable, Sendable {
    let noteID: UUID
    let folderID: UUID
    let title: String
    let bodyPlainText: String
    let savedRevision: Int64
}

enum RecoveryCopyError: Error, Equatable, Sendable {
    case writeFailed
    case verificationFailed
}

extension RecoveryCopyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .writeFailed:
            "The recovery copy could not be written. Choose another location and try again."
        case .verificationFailed:
            "The recovery copy was written but did not read back correctly, so it was not reported as saved."
        }
    }
}

/// A user-chosen JSON file that holds unsaved text. It is only reported as saved after it reads back unchanged.
enum RecoveryCopy {
    static let format = "jaasnotes.recovery"
    static let version = 1

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let exportedAt: Date
        let drafts: [RecoveryDraft]
    }

    static func write(_ drafts: [RecoveryDraft], to url: URL, exportedAt: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = Envelope(format: format, version: version, exportedAt: exportedAt, drafts: drafts)

        let data: Data
        do {
            data = try encoder.encode(envelope)
            try data.write(to: url, options: .atomic)
        } catch {
            throw RecoveryCopyError.writeFailed
        }

        // Check the bytes on disk, not the buffer that was just encoded. Any read-back problem counts as a failure.
        let readBack: [RecoveryDraft]
        do {
            readBack = try read(from: url)
        } catch {
            throw RecoveryCopyError.verificationFailed
        }
        guard readBack == drafts else {
            throw RecoveryCopyError.verificationFailed
        }
    }

    static func read(from url: URL) throws -> [RecoveryDraft] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.format == format, envelope.version == version else {
            throw RecoveryCopyError.verificationFailed
        }
        return envelope.drafts
    }
}
