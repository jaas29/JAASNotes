import AppKit
import XCTest
@testable import JAASNotes

/// The formatting commands on the editor's text view, driven directly (03-02). Each runs in a window so undo works as it does in the app.
@MainActor
final class RichFormattingTests: XCTestCase {
    private func makeEditor(
        plain text: String? = nil,
        rich attributed: NSAttributedString? = nil,
        editable: Bool = true,
        requested: @escaping (NSAttributedString) -> Void = { _ in }
    ) -> (NoteTextView, NSWindow) {
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.isRichText = attributed != nil
        textView.allowsUndo = true
        textView.isEditable = editable
        textView.onRichTextRequested = requested
        if let attributed {
            textView.textStorage?.setAttributedString(attributed)
        } else {
            textView.string = text ?? ""
        }
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        return (textView, window)
    }

    private func richText(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    }

    private func hasTrait(_ trait: NSFontTraitMask, in textView: NSTextView, at index: Int) -> Bool {
        let font = textView.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        return NSFontManager.shared.traits(of: font).contains(trait)
    }

    private func fontSize(in textView: NSTextView, at index: Int) -> CGFloat {
        (textView.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    private func textLists(in textView: NSTextView, at index: Int) -> [NSTextList] {
        (textView.textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    // MARK: - Inline styles

    func testBoldAppliesToTheSelectionOnly() {
        let (textView, _) = makeEditor(rich: richText("Hello world"))
        textView.setSelectedRange(NSRange(location: 6, length: 5))

        textView.toggleBold(nil)

        XCTAssertTrue(hasTrait(.boldFontMask, in: textView, at: 7))
        XCTAssertFalse(hasTrait(.boldFontMask, in: textView, at: 1), "Text outside the selection keeps its style.")
    }

    func testBoldToggledAgainRemovesIt() {
        let (textView, _) = makeEditor(rich: richText("Hello world"))
        textView.setSelectedRange(NSRange(location: 6, length: 5))

        textView.toggleBold(nil)
        textView.toggleBold(nil)

        XCTAssertFalse(hasTrait(.boldFontMask, in: textView, at: 7))
    }

    func testItalicAndUnderlineApplyToTheSelection() {
        let (textView, _) = makeEditor(rich: richText("Hello world"))
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.toggleItalic(nil)
        textView.toggleUnderline(nil)

        XCTAssertTrue(hasTrait(.italicFontMask, in: textView, at: 2))
        XCTAssertEqual(textView.textStorage?.attribute(.underlineStyle, at: 2, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(textView.textStorage?.attribute(.underlineStyle, at: 7, effectiveRange: nil))
    }

    func testWithNoSelectionTheTypingStyleChanges() {
        let (textView, _) = makeEditor(rich: richText("Hello"))
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.toggleBold(nil)

        let typingFont = textView.typingAttributes[.font] as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: typingFont ?? .systemFont(ofSize: 13)).contains(.boldFontMask))
    }

    func testUndoRevertsFormatting() throws {
        let (textView, window) = makeEditor(rich: richText("Hello world"))
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        textView.toggleBold(nil)
        XCTAssertTrue(hasTrait(.boldFontMask, in: textView, at: 7))

        let undoManager = try XCTUnwrap(window.undoManager, "The window needs an undo manager for this test.")
        undoManager.undo()

        XCTAssertFalse(hasTrait(.boldFontMask, in: textView, at: 7), "Undo must restore the text's previous style.")
    }

    // MARK: - Headings and lists

    func testHeadingSetsTheParagraphSizeAndBold() {
        let (textView, _) = makeEditor(rich: richText("Title\nBody"))
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.applyHeading1(nil)

        XCTAssertEqual(fontSize(in: textView, at: 1), 26)
        XCTAssertTrue(hasTrait(.boldFontMask, in: textView, at: 1))
        XCTAssertEqual(fontSize(in: textView, at: 7), 13, "The next paragraph is not part of the heading.")
    }

    func testBodyTextResetsAHeading() {
        let (textView, _) = makeEditor(rich: richText("Title"))
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.applyHeading2(nil)

        textView.applyBodyText(nil)

        XCTAssertFalse(hasTrait(.boldFontMask, in: textView, at: 1))
        XCTAssertNotEqual(fontSize(in: textView, at: 1), 20)
    }

    func testBulletedListTogglesOnTheParagraph() {
        let (textView, _) = makeEditor(rich: richText("One\nTwo"))
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.toggleBulletList(nil)
        XCTAssertEqual(textLists(in: textView, at: 0).map(\.markerFormat), [.disc])
        XCTAssertTrue(textLists(in: textView, at: 5).isEmpty, "The second paragraph is not a bullet.")

        textView.toggleBulletList(nil)
        XCTAssertTrue(textLists(in: textView, at: 0).isEmpty)
    }

    // MARK: - Plain notes and read-only notes

    func testFormattingAPlainNoteAsksForRichTextOnce() {
        var requests: [String] = []
        let (textView, _) = makeEditor(plain: "Plain text") { requests.append($0.string) }
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.toggleBold(nil)
        textView.toggleItalic(nil)

        XCTAssertTrue(textView.isRichText, "The first formatting command turns rich text on.")
        XCTAssertEqual(requests, ["Plain text"], "The model is asked once, with the current text.")
        XCTAssertTrue(hasTrait(.boldFontMask, in: textView, at: 1))
    }

    func testTypingInAPlainNoteDoesNotMakeItRich() {
        var requests = 0
        let (textView, _) = makeEditor(plain: "Plain") { _ in requests += 1 }
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.insertText(" more", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(textView.isRichText)
        XCTAssertEqual(requests, 0)
    }

    func testReadOnlyNoteIgnoresFormattingCommands() {
        var requests = 0
        let (textView, _) = makeEditor(rich: richText("Locked"), editable: false) { _ in requests += 1 }
        textView.setSelectedRange(NSRange(location: 0, length: 6))

        textView.toggleBold(nil)
        textView.toggleBulletList(nil)

        XCTAssertFalse(hasTrait(.boldFontMask, in: textView, at: 1))
        XCTAssertTrue(textLists(in: textView, at: 0).isEmpty)
        XCTAssertEqual(requests, 0)
    }

    // MARK: - Saved form

    func testHeadingAndBulletsSurviveTheRTFRoundTrip() throws {
        let (textView, _) = makeEditor(rich: richText("Shopping\nMilk"))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.applyHeading1(nil)
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        textView.toggleBulletList(nil)

        let content = try RichTextCodec.content(from: textView.attributedString(), checklist: nil)
        let decoded = try RichTextCodec.attributedString(of: content)

        XCTAssertEqual(decoded.attribute(.font, at: 1, effectiveRange: nil).flatMap { ($0 as? NSFont)?.pointSize }, 26)
        let lists = (decoded.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
        XCTAssertEqual(lists.map(\.markerFormat), [.disc], "Bullets are kept through RTF, or the list would silently disappear on reopen.")
    }

    // MARK: - Ordinary saves

    func testSynchronizingUnchangedTextKeepsSelectionAndUndo() {
        let (textView, window) = makeEditor(rich: richText("Hello world"))
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        textView.toggleBold(nil)
        let saved = textView.attributedString()

        // What a save does: the model hands back the same body the view already shows.
        NoteBodyEditor.synchronize(textView, plainText: saved.string, richText: saved, checklist: nil)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 5), "A save must not move the selection.")
        let undoManager = try? XCTUnwrap(window.undoManager)
        undoManager?.undo()
        XCTAssertFalse(hasTrait(.boldFontMask, in: textView, at: 7), "Undo history must survive the save.")
    }

    func testSynchronizingChangedTextReplacesIt() {
        let (textView, _) = makeEditor(rich: richText("Hello"))

        NoteBodyEditor.synchronize(textView, plainText: "Other", richText: richText("Other"), checklist: nil)

        XCTAssertEqual(textView.string, "Other")
    }
}
