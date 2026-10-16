import AppKit
import XCTest
@testable import JAASNotes

/// Checklist behavior in the real text view: typing, Return, undo, checkbox controls, and the Format commands (03-03).
@MainActor
final class ChecklistEditorTests: XCTestCase {
    private let noRange = NSRange(location: NSNotFound, length: 0)
    private let firstID = UUID()
    private let secondID = UUID()

    private func makeEditor(text: String, checklist: ChecklistSidecar?, rich: Bool = true, reported: @escaping (ChecklistSidecar?) -> Void = { _ in }) -> (NoteTextView, NSWindow) {
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.isRichText = rich
        textView.allowsUndo = true
        textView.onRichEdit = { _, list in reported(list) }
        textView.onRichTextRequested = { _ in }
        if rich {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            textView.setChecklist(checklist)
        } else {
            textView.string = text
        }
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        return (textView, window)
    }

    /// "Buy milk" (checked) and "Eggs 🥚" (unchecked).
    private var sample: ChecklistSidecar {
        ChecklistSidecar(items: [
            ChecklistItem(id: firstID, isChecked: true, location: 0, length: 8),
            ChecklistItem(id: secondID, isChecked: false, location: 9, length: 7),
        ])
    }

    private func checkboxes(in textView: NSTextView) -> [NSButton] {
        textView.subviews.compactMap { $0 as? NSButton }
    }

    func testTypingInsideAnItemKeepsItsIdentity() {
        let (textView, _) = makeEditor(text: "Buy milk\nEggs 🥚", checklist: sample)
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        textView.insertText("!", replacementRange: noRange)

        XCTAssertEqual(textView.checklist?.items.first?.id, firstID)
        XCTAssertEqual(textView.checklist?.items.first?.isChecked, true)
        XCTAssertEqual(textView.checklist?.items.first?.length, 9)
        XCTAssertEqual(textView.checklist?.items.last?.location, 10, "The second item moves with its paragraph.")
    }

    func testReturnAtTheEndOfAnItemAddsAnUncheckedItem() {
        let (textView, _) = makeEditor(text: "Buy milk\nEggs 🥚", checklist: sample)
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        textView.insertText("\n", replacementRange: noRange)

        let items = textView.checklist?.items ?? []
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.isChecked, true)
        XCTAssertEqual(items[1].isChecked, false)
        XCTAssertFalse([firstID, secondID].contains(items[1].id), "The new item has its own identity.")
    }

    func testUndoRestoresTextAndChecklistTogether() throws {
        let (textView, window) = makeEditor(text: "Buy milk\nEggs 🥚", checklist: sample)
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText("\n", replacementRange: noRange)
        XCTAssertEqual(textView.checklist?.items.count, 3)

        try XCTUnwrap(window.undoManager).undo()

        XCTAssertEqual(textView.string, "Buy milk\nEggs 🥚", "The text is back to its earlier state.")
        XCTAssertEqual(textView.checklist, sample, "The checklist is back with the same identities and states.")
    }

    func testCheckboxClickTogglesTheItemReportsItAndUndoes() throws {
        var reported: [ChecklistSidecar?] = []
        let (textView, window) = makeEditor(text: "Buy milk\nEggs 🥚", checklist: sample) { reported.append($0) }
        textView.layoutSubtreeIfNeeded()
        let box = try XCTUnwrap(checkboxes(in: textView).first { $0.identifier?.rawValue == firstID.uuidString })
        XCTAssertEqual(box.state, .on)
        XCTAssertTrue(box.accessibilityLabel()?.hasPrefix("Checklist item") ?? false)

        box.performClick(nil)

        XCTAssertEqual(textView.checklist?.items.first?.isChecked, false)
        XCTAssertEqual(reported.last??.items.first?.isChecked, false, "The model is told about the change.")
        try XCTUnwrap(window.undoManager).undo()
        XCTAssertEqual(textView.checklist?.items.first?.isChecked, true)
    }

    func testChecklistCommandAddsItemsAndRemovesThemAgain() {
        let (textView, _) = makeEditor(text: "One\nTwo", checklist: nil)
        textView.setSelectedRange(NSRange(location: 0, length: 7))

        textView.toggleChecklist(nil)
        XCTAssertEqual(textView.checklist?.items.map(\.location), [0, 4])
        XCTAssertEqual(checkboxes(in: textView).count, 2, "Each item has a checkbox.")

        textView.toggleChecklist(nil)
        XCTAssertEqual(textView.checklist?.items.count ?? 0, 0)
        XCTAssertEqual(checkboxes(in: textView).count, 0)
    }

    func testCheckShortcutTogglesTheItemOnTheInsertionPoint() {
        let (textView, _) = makeEditor(text: "Buy milk\nEggs 🥚", checklist: sample)
        textView.setSelectedRange(NSRange(location: 12, length: 0))

        textView.toggleCheckedItem(nil)

        XCTAssertEqual(textView.checklist?.items.last?.isChecked, true)
        XCTAssertEqual(textView.checklist?.items.first?.isChecked, true, "Other items keep their state.")
    }

    /// Plain-text paste inserts through the same path as typing. The system pasteboard is not used, so the test leaves the clipboard alone.
    func testPastedLinesInsideAnItemKeepTheItemAndItsIndent() {
        let (textView, _) = makeEditor(text: "Buy milk\nEggs 🥚", checklist: sample)
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        textView.insertText("one\ntwo", replacementRange: noRange)

        XCTAssertEqual(textView.string, "Buyone\ntwo milk\nEggs 🥚")
        XCTAssertEqual(textView.checklist?.items.first?.id, firstID, "The text before the paste keeps the item.")
        XCTAssertEqual(textView.checklist?.items.count, 3, "The pasted second line is a new, unchecked item.")
        let style = textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 24, "Checklist paragraphs keep their checkbox gutter.")
    }

    func testPlainNoteChecklistCommandAsksForRichText() {
        var requested = 0
        let (textView, _) = makeEditor(text: "Plain", checklist: nil, rich: false)
        textView.onRichTextRequested = { _ in requested += 1 }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        textView.toggleChecklist(nil)

        XCTAssertEqual(requested, 1)
        XCTAssertTrue(textView.isRichText)
        XCTAssertEqual(textView.checklist?.items.count, 1)
    }
}
