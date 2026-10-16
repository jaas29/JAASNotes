import Foundation

/// A note body with formatting: RTF for the text and its formatting, a checklist sidecar, and the plain text derived
/// from the RTF. The plain text is what search and previews read. Notes with no rich body keep only plain text.
struct RichNoteContent: Equatable, Sendable {
    /// The value of `contentFormatVersion` for a note with a rich body. 0 means plain text only.
    static let formatVersion = 1

    let rtf: Data
    let checklist: ChecklistSidecar?
    let plainText: String
}

/// Checklist state, stored apart from the RTF. Items refer to paragraphs by UTF-16 range in the plain text, so
/// formatting is never needed to remember which paragraphs are checkable.
struct ChecklistSidecar: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let items: [ChecklistItem]

    init(items: [ChecklistItem]) {
        self.version = Self.currentVersion
        self.items = items
    }
}

struct ChecklistItem: Codable, Equatable, Sendable, Identifiable {
    /// Stable across edits, saves, and restarts. It identifies the item, not its position.
    let id: UUID
    var isChecked: Bool
    /// UTF-16 offset of the paragraph's first character in the plain text.
    let location: Int
    /// UTF-16 length of the paragraph's text, excluding its line break.
    let length: Int
}

/// Why rich content was refused. Messages never include note text.
enum RichContentError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int)
    case notReadableRTF
    case unsupportedContent(String)
    case plainTextMismatch
    case unsupportedChecklistVersion(Int)
    case invalidChecklist(String)
    case unsupportedContentFormat(Int)
}

extension RichContentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "This note's formatting is too large to save."
        case .notReadableRTF:
            "The formatting in this note could not be read."
        case .unsupportedContent(let detail):
            "This note contains content JAASNotes cannot store yet (\(detail))."
        case .plainTextMismatch:
            "The saved text does not match the formatting, so the note was left unchanged."
        case .unsupportedChecklistVersion(let version):
            "The checklist was written by a newer version of JAASNotes (format \(version))."
        case .invalidChecklist(let detail):
            "The checklist in this note is damaged (\(detail))."
        case .unsupportedContentFormat(let version):
            "This note was written in a newer rich-text format (\(version))."
        }
    }
}

extension ChecklistSidecar {
    /// Checks that every item is a paragraph of `plainText`, that items are ordered and do not overlap, and that no
    /// range splits a line or a composed character (an emoji, or a letter with combining marks).
    func validate(against plainText: String) throws {
        guard version == Self.currentVersion else {
            throw RichContentError.unsupportedChecklistVersion(version)
        }
        let text = plainText as NSString
        var seen = Set<UUID>()
        var previousEnd: Int?

        for item in items {
            guard seen.insert(item.id).inserted else {
                throw RichContentError.invalidChecklist("duplicate item")
            }
            guard item.location >= 0, item.length >= 0, item.location + item.length <= text.length else {
                throw RichContentError.invalidChecklist("range outside the note")
            }
            if let previousEnd, item.location <= previousEnd {
                throw RichContentError.invalidChecklist("items overlap or are out of order")
            }
            let end = item.location + item.length

            // A line break inside the range would make it more than one paragraph.
            for index in item.location..<end where text.character(at: index) == Self.lineFeed {
                throw RichContentError.invalidChecklist("range spans more than one paragraph")
            }
            let startsParagraph = item.location == 0 || text.character(at: item.location - 1) == Self.lineFeed
            let endsParagraph = end == text.length || text.character(at: end) == Self.lineFeed
            guard startsParagraph, endsParagraph else {
                throw RichContentError.invalidChecklist("range is not a whole paragraph")
            }
            // Both boundaries must fall between composed characters. An index at the very end has nothing to split.
            let startIsBoundary = item.location == text.length
                || text.rangeOfComposedCharacterSequence(at: item.location).location == item.location
            let endIsBoundary = end == text.length
                || text.rangeOfComposedCharacterSequence(at: end).location == end
            guard startIsBoundary, endIsBoundary else {
                throw RichContentError.invalidChecklist("range splits a character")
            }
            previousEnd = end
        }
    }

    static let lineFeed: unichar = 0x0A
}

/// The body of a note as read from the store. Editors and exports read this; list rows read only `NoteSnapshot`.
enum NoteBody: Equatable, Sendable {
    case plain(String)
    case rich(RichNoteContent)
    /// The stored formatting could not be read or validated. `fallbackText` is the plain text saved alongside it.
    /// The stored data is left untouched; a recovery copy keeps the text without replacing the original.
    case unreadable(fallbackText: String, reason: String)
}
