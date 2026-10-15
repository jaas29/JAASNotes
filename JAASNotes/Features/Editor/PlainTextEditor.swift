import AppKit
import SwiftUI

/// Plain-text body editor backed by NSTextView, so native selection, undo, spelling, and input methods all apply.
struct PlainTextEditor: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void

    func makeCoordinator() -> PlainTextEditorDelegate {
        PlainTextEditorDelegate(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("Note body")
        textView.setAccessibilityIdentifier("noteBody")
        textView.delegate = context.coordinator
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onChange = onChange

        // Replacing text during an input-method composition would discard the marked text.
        // The view only needs replacing when the model differs from what is on screen.
        guard !textView.hasMarkedText(), textView.string != text else { return }
        textView.string = text
    }
}

/// Reports committed text changes. Provisional input-method text (marked text) is not reported.
final class PlainTextEditorDelegate: NSObject, NSTextViewDelegate {
    var onChange: (String) -> Void

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
        onChange(textView.string)
    }
}
