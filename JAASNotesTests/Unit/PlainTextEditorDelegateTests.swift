import AppKit
import XCTest
@testable import JAASNotes

@MainActor
final class PlainTextEditorDelegateTests: XCTestCase {
    private let noRange = NSRange(location: NSNotFound, length: 0)

    private func makeTextView(reporting reported: @escaping (String) -> Void) -> (NSTextView, PlainTextEditorDelegate) {
        let delegate = PlainTextEditorDelegate(onChange: reported)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = delegate
        return (textView, delegate)
    }

    func testCommittedTypingReportsTheWholeText() {
        var reported: [String] = []
        let (textView, delegate) = makeTextView { reported.append($0) }

        textView.insertText("Café 🧪", replacementRange: noRange)

        XCTAssertEqual(reported.last, "Café 🧪")
        XCTAssertEqual(textView.string, "Café 🧪")
        withExtendedLifetime(delegate) {}
    }

    func testProvisionalInputMethodTextIsNotReportedUntilCommitted() {
        var reported: [String] = []
        let (textView, delegate) = makeTextView { reported.append($0) }

        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: noRange)
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertTrue(reported.isEmpty, "Marked text must not be saved as if it were final.")

        textView.insertText("你", replacementRange: noRange)
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(reported, ["你"])
        withExtendedLifetime(delegate) {}
    }
}
