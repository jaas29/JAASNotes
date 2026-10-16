import Foundation

/// Converts between note formatting and its stored form (RTF plus a checklist sidecar). These are pure functions:
/// they never touch the store. Anything they refuse is refused before it reaches a file.
enum RichTextCodec {
    /// Provisional limit for one note's RTF. Clear rejection beats an unbounded write.
    static let maximumRTFBytes = 16 * 1024 * 1024

    // MARK: - Writing

    /// Builds validated content from edited text. The stored text is read back from the encoded RTF, so the search
    /// text always matches what a later read produces.
    ///
    /// RTF stores text in precomposed form, so a letter followed by a combining mark is saved as one character.
    /// Checklist ranges are given against `plainText(of: text)` and are remapped paragraph by paragraph to the stored text.
    static func content(from text: NSAttributedString, checklist: ChecklistSidecar?) throws -> RichNoteContent {
        try refuseAttachments(in: text)
        let sourcePlain = plainText(of: text)
        try checklist?.validate(against: sourcePlain)

        let rtf = try rtfData(from: text)
        let storedPlain = plainText(of: try attributedString(fromRTF: rtf))
        let stored = try checklist.map { try remap($0, from: sourcePlain, to: storedPlain) }
        try stored?.validate(against: storedPlain)
        return RichNoteContent(rtf: rtf, checklist: stored, plainText: storedPlain)
    }

    /// Checks content that is about to be written. Repositories call this so a bad caller cannot store content that
    /// would later be unreadable.
    static func validate(_ content: RichNoteContent) throws {
        try checkSize(content.rtf)
        let decoded = try attributedString(fromRTF: content.rtf)
        guard plainText(of: decoded) == content.plainText else {
            throw RichContentError.plainTextMismatch
        }
        try content.checklist?.validate(against: content.plainText)
    }

    // MARK: - Reading

    /// Reads stored RTF and checklist data. Throws if either is damaged, unsupported, or inconsistent with each other.
    static func content(rtf: Data, checklistData: Data?) throws -> RichNoteContent {
        try checkSize(rtf)
        let decoded = try attributedString(fromRTF: rtf)
        let plain = plainText(of: decoded)
        let checklist = try checklistData.map(decodeChecklist)
        try checklist?.validate(against: plain)
        return RichNoteContent(rtf: rtf, checklist: checklist, plainText: plain)
    }

    /// The text an editor starts from. Attachments were rejected when the content was read, so this is text and formatting only.
    static func attributedString(of content: RichNoteContent) throws -> NSAttributedString {
        try attributedString(fromRTF: content.rtf)
    }

    // MARK: - Plain text

    /// Plain text with every kind of line break written as "\n", so checklist ranges agree on every platform path.
    static func plainText(of text: NSAttributedString) -> String {
        text.string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    // MARK: - Checklist sidecar

    static func encodeChecklist(_ checklist: ChecklistSidecar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(checklist)
    }

    static func decodeChecklist(_ data: Data) throws -> ChecklistSidecar {
        do {
            return try JSONDecoder().decode(ChecklistSidecar.self, from: data)
        } catch {
            throw RichContentError.invalidChecklist("unreadable data")
        }
    }

    // MARK: - RTF

    /// RTF writing drops attachments without an error, so they are refused before anything is written.
    private static func refuseAttachments(in text: NSAttributedString) throws {
        var hasAttachment = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                hasAttachment = true
                stop.pointee = true
            }
        }
        if hasAttachment {
            throw RichContentError.unsupportedContent("attachment")
        }
    }

    /// Moves each checklist item to the same paragraph in `target`. The paragraphs must line up one for one, which
    /// composing characters never change because they do not change line breaks.
    private static func remap(_ checklist: ChecklistSidecar, from source: String, to target: String) throws -> ChecklistSidecar {
        let sourceParagraphs = ChecklistEditing.paragraphRanges(in: source as NSString)
        let targetParagraphs = ChecklistEditing.paragraphRanges(in: target as NSString)
        guard sourceParagraphs.count == targetParagraphs.count else {
            throw RichContentError.invalidChecklist("the paragraphs changed while saving")
        }
        let indexByStart = Dictionary(uniqueKeysWithValues: sourceParagraphs.enumerated().map { ($0.element.location, $0.offset) })
        let items = try checklist.items.map { item -> ChecklistItem in
            guard let index = indexByStart[item.location] else {
                throw RichContentError.invalidChecklist("range is not a whole paragraph")
            }
            let paragraph = targetParagraphs[index]
            return ChecklistItem(id: item.id, isChecked: item.isChecked, location: paragraph.location, length: paragraph.length)
        }
        return ChecklistSidecar(items: items)
    }

    private static func rtfData(from text: NSAttributedString) throws -> Data {
        let data: Data
        do {
            data = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        } catch {
            throw RichContentError.notReadableRTF
        }
        try checkSize(data)
        return data
    }

    /// Reads RTF and refuses content the app cannot store. Inline attachments (pictures, files) are not supported in Stage 3.
    private static func attributedString(fromRTF data: Data) throws -> NSAttributedString {
        try checkSize(data)
        var documentAttributes: NSDictionary?
        let decoded: NSAttributedString
        do {
            decoded = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: &documentAttributes
            )
        } catch {
            throw RichContentError.notReadableRTF
        }
        try refuseAttachments(in: decoded)
        return decoded
    }

    private static func checkSize(_ data: Data) throws {
        guard data.count <= maximumRTFBytes else {
            throw RichContentError.tooLarge(bytes: data.count)
        }
    }
}
