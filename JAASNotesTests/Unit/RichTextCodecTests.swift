import AppKit
import XCTest
@testable import JAASNotes

/// RTF and checklist serialization and validation (03-01). Pure functions; no store is involved.
final class RichTextCodecTests: XCTestCase {
    /// Text that has broken other editors: combining marks, emoji sequences, CJK, right-to-left scripts, and RTF control characters.
    private let samples = [
        "Línea uno\n日本語のメモ",
        "Emoji 🧪 and family 👨‍👩‍👧 done",
        "Cafe\u{301} with a combining accent",
        "مرحبا بالعالم",
        "שלום עולם",
        "Braces { } and a backslash \\ rtf1 \\par",
        "Tab\tand\ttabs",
    ]

    // MARK: - RTF round trips

    /// Compares scalars. `String ==` treats canonically equivalent text as equal, which would hide a change of encoding.
    private func assertSameScalars(_ lhs: String, _ rhs: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars), "Scalars differ: \(lhs) vs \(rhs)", file: file, line: line)
    }

    func testUnicodeTextRoundTripsThroughRTFInPrecomposedForm() throws {
        for sample in samples {
            let content = try RichTextCodec.content(from: NSAttributedString(string: sample), checklist: nil)
            let reread = try RichTextCodec.content(rtf: content.rtf, checklistData: nil)

            // RTF stores precomposed text, so the expected value is the NFC form of each sample.
            assertSameScalars(reread.plainText, sample.precomposedStringWithCanonicalMapping)
        }
    }

    func testCombiningMarksAreStoredPrecomposedAndChecklistFollowsItsParagraph() throws {
        // "Cafe" + combining acute is 5 UTF-16 units; stored as "Café" it is 4. The second paragraph moves with it.
        let source = "Cafe\u{301}\nNext"
        let checkedID = UUID()
        let laterID = UUID()
        let checklist = ChecklistSidecar(items: [
            ChecklistItem(id: checkedID, isChecked: true, location: 0, length: 5),
            ChecklistItem(id: laterID, isChecked: false, location: 6, length: 4),
        ])

        let content = try RichTextCodec.content(from: NSAttributedString(string: source), checklist: checklist)

        assertSameScalars(content.plainText, "Café\nNext")
        XCTAssertEqual(content.checklist?.items.map(\.id), [checkedID, laterID])
        XCTAssertEqual(content.checklist?.items.map(\.location), [0, 5])
        XCTAssertEqual(content.checklist?.items.map(\.length), [4, 4])
        XCTAssertEqual(content.checklist?.items.map(\.isChecked), [true, false])
    }

    func testFormattingSurvivesRoundTrip() throws {
        let text = NSMutableAttributedString(string: "Plain bold italic underlined")
        let bold = NSFont.boldSystemFont(ofSize: 14)
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)
        text.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))
        text.addAttribute(.font, value: italic, range: NSRange(location: 11, length: 6))
        text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 18, length: 10))

        let content = try RichTextCodec.content(from: text, checklist: nil)
        let decoded = try RichTextCodec.attributedString(of: content)

        let boldFont = try XCTUnwrap(decoded.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        let italicFont = try XCTUnwrap(decoded.attribute(.font, at: 12, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
        let underline = decoded.attribute(.underlineStyle, at: 20, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(decoded.string, "Plain bold italic underlined")
    }

    func testLineBreakKindsAreNormalizedToLineFeeds() {
        let mixed = NSAttributedString(string: "a\r\nb\rc\u{2028}d\u{2029}e\nf")
        XCTAssertEqual(RichTextCodec.plainText(of: mixed), "a\nb\nc\nd\ne\nf")
    }

    // MARK: - Refusals

    func testBytesThatAreNotRTFAreRefused() {
        for data in [Data("not rtf at all".utf8), Data()] {
            XCTAssertThrowsError(try RichTextCodec.content(rtf: data, checklistData: nil)) { error in
                XCTAssertEqual(error as? RichContentError, .notReadableRTF)
            }
        }
    }

    func testOversizedRTFIsRefusedBeforeItIsParsed() {
        let oversized = Data(count: RichTextCodec.maximumRTFBytes + 1)
        XCTAssertThrowsError(try RichTextCodec.content(rtf: oversized, checklistData: nil)) { error in
            XCTAssertEqual(error as? RichContentError, .tooLarge(bytes: oversized.count))
        }
    }

    func testInlineAttachmentsAreRefusedBeforeSaving() {
        let text = NSMutableAttributedString(string: "x")
        text.addAttribute(.attachment, value: NSTextAttachment(), range: NSRange(location: 0, length: 1))

        XCTAssertThrowsError(try RichTextCodec.content(from: text, checklist: nil)) { error in
            guard case .unsupportedContent = error as? RichContentError else {
                return XCTFail("Expected an unsupported-content refusal, got \(error)")
            }
        }
    }

    func testStoredPlainTextMustMatchTheRTF() throws {
        let good = try RichTextCodec.content(from: NSAttributedString(string: "Hello"), checklist: nil)
        let forged = RichNoteContent(rtf: good.rtf, checklist: nil, plainText: "Something else")

        XCTAssertThrowsError(try RichTextCodec.validate(forged)) { error in
            XCTAssertEqual(error as? RichContentError, .plainTextMismatch)
        }
        XCTAssertNoThrow(try RichTextCodec.validate(good))
    }

    // MARK: - Checklist

    /// Four paragraphs: ASCII, Japanese, an emoji sequence, and a last line with no break after it.
    private let checklistText = "Buy milk\n日本語\n😀 smile\nLast"

    private func item(_ location: Int, _ length: Int, checked: Bool = false, id: UUID = UUID()) -> ChecklistItem {
        ChecklistItem(id: id, isChecked: checked, location: location, length: length)
    }

    func testChecklistOnWholeParagraphsOfUnicodeTextIsValid() throws {
        let sidecar = ChecklistSidecar(items: [
            item(0, 8),
            item(9, 3, checked: true),
            item(13, 8),
            item(22, 4),
        ])
        XCTAssertNoThrow(try sidecar.validate(against: checklistText))
    }

    func testEmptyParagraphCanBeAChecklistItem() throws {
        let sidecar = ChecklistSidecar(items: [item(2, 0)])
        XCTAssertNoThrow(try sidecar.validate(against: "a\n\nb"))
    }

    func testChecklistRejectsRangesThatAreNotWholeParagraphs() {
        let cases: [(String, [ChecklistItem])] = [
            ("outside the text", [item(20, 10)]),
            ("negative location", [item(-1, 3)]),
            ("part of a paragraph", [item(1, 3)]),
            ("splits an emoji", [item(13, 1)]),
            ("crosses a line break", [item(0, 12)]),
            ("overlapping items", [item(0, 8), item(4, 4)]),
            ("out of order", [item(13, 8), item(0, 8)]),
            ("duplicate identifiers", [item(0, 8, id: sharedID), item(13, 8, id: sharedID)]),
        ]
        for (name, items) in cases {
            XCTAssertThrowsError(try ChecklistSidecar(items: items).validate(against: checklistText), name) { error in
                guard case .invalidChecklist = error as? RichContentError else {
                    return XCTFail("\(name): expected an invalid-checklist refusal, got \(error)")
                }
            }
        }
    }

    private let sharedID = UUID()

    func testChecklistFromANewerFormatIsRefused() {
        let newer = ChecklistSidecar(items: [])
        var data = try! RichTextCodec.encodeChecklist(newer)
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":9").utf8)

        XCTAssertThrowsError(try RichTextCodec.decodeChecklist(data).validate(against: "")) { error in
            XCTAssertEqual(error as? RichContentError, .unsupportedChecklistVersion(9))
        }
    }

    func testDamagedChecklistDataIsRefused() {
        XCTAssertThrowsError(try RichTextCodec.decodeChecklist(Data("{not json".utf8))) { error in
            guard case .invalidChecklist = error as? RichContentError else {
                return XCTFail("Expected an invalid-checklist refusal, got \(error)")
            }
        }
    }

    func testChecklistIdentityAndCheckedStateRoundTrip() throws {
        let first = UUID()
        let second = UUID()
        let original = ChecklistSidecar(items: [
            ChecklistItem(id: first, isChecked: true, location: 0, length: 8),
            ChecklistItem(id: second, isChecked: false, location: 13, length: 8),
        ])
        let sample = NSAttributedString(string: checklistText)
        let content = try RichTextCodec.content(from: sample, checklist: original)
        let stored = try RichTextCodec.encodeChecklist(original)

        let reread = try RichTextCodec.content(rtf: content.rtf, checklistData: stored)

        XCTAssertEqual(reread.checklist, original)
        XCTAssertEqual(reread.checklist?.items.map(\.id), [first, second])
    }

    func testChecklistThatDoesNotMatchTheTextIsRefusedOnRead() throws {
        let content = try RichTextCodec.content(from: NSAttributedString(string: "Short"), checklist: nil)
        let stored = try RichTextCodec.encodeChecklist(ChecklistSidecar(items: [
            ChecklistItem(id: UUID(), isChecked: false, location: 0, length: 40),
        ]))
        XCTAssertThrowsError(try RichTextCodec.content(rtf: content.rtf, checklistData: stored))
    }
}
