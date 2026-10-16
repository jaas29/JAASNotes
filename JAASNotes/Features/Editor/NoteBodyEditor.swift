import AppKit
import SwiftUI

/// Note body editor backed by NSTextView, so native selection, undo, spelling, input methods, and the font commands apply.
/// A plain note edits plain text. A formatted note edits its RTF and checklist. The first formatting command on a plain
/// note makes the note formatted through `onRichTextRequested`; plain notes stay plain unless the user formats them.
struct NoteBodyEditor: NSViewRepresentable {
    let plainText: String
    /// The formatted body, or nil for a plain note.
    let richText: NSAttributedString?
    /// The checklist for a formatted note. Ignored for a plain note.
    var checklist: ChecklistSidecar? = nil
    var isEditable = true
    let onPlainChange: (String) -> Void
    let onRichChange: (NSAttributedString, ChecklistSidecar?) -> Void
    let onRichTextRequested: (NSAttributedString) -> Void

    func makeCoordinator() -> NoteBodyEditorDelegate {
        NoteBodyEditorDelegate(onPlainChange: onPlainChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView()
        textView.isRichText = richText != nil
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Cmd-F in the body opens the native find bar (Find in Note).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("Note body")
        textView.setAccessibilityIdentifier("noteBody")
        textView.onRichTextRequested = onRichTextRequested
        textView.onRichEdit = onRichChange
        textView.delegate = context.coordinator
        if let richText {
            textView.textStorage?.setAttributedString(richText)
            textView.setChecklist(checklist)
        } else {
            textView.string = plainText
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        context.coordinator.onPlainChange = onPlainChange
        textView.onRichTextRequested = onRichTextRequested
        textView.onRichEdit = onRichChange
        textView.isEditable = isEditable
        Self.synchronize(textView, plainText: plainText, richText: richText, checklist: checklist)
    }

    /// Makes the text view show the model's body. Text is replaced only when it differs, so selection, scroll position,
    /// and undo history survive an ordinary save, which never changes the text. Marked (input-method) text is left alone.
    static func synchronize(_ textView: NoteTextView, plainText: String, richText: NSAttributedString?, checklist: ChecklistSidecar?) {
        guard !textView.hasMarkedText() else { return }
        if let richText {
            if !textView.isRichText {
                textView.isRichText = true
            }
            if !textView.attributedString().isEqual(to: richText) {
                textView.textStorage?.setAttributedString(richText)
            }
            if textView.checklist != checklist {
                textView.setChecklist(checklist)
            }
        } else if textView.string != plainText {
            textView.string = plainText
        }
    }
}

/// Reports committed changes to plain text. Formatted notes report from `NoteTextView`, which also tracks the checklist.
final class NoteBodyEditorDelegate: NSObject, NSTextViewDelegate {
    var onPlainChange: (String) -> Void

    init(onPlainChange: @escaping (String) -> Void) {
        self.onPlainChange = onPlainChange
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, !textView.hasMarkedText(), !textView.isRichText else { return }
        onPlainChange(textView.string)
    }
}

/// The body text view. The Format menu sends these selectors through the responder chain.
///
/// Checklist items are kept on their paragraphs as the text changes. Each change is also an undo step for the checklist,
/// registered alongside the text's own undo step, so undo restores both.
final class NoteTextView: NSTextView {
    /// Called when a plain note first receives a formatting command. It receives the current text, now formatted.
    var onRichTextRequested: ((NSAttributedString) -> Void)?
    /// Called after each change to a formatted note's text or checklist.
    var onRichEdit: ((NSAttributedString, ChecklistSidecar?) -> Void)?

    /// The checklist for the current text. Set with `setChecklist` for saved state, or changed by edits here.
    private(set) var checklist: ChecklistSidecar?
    private var pendingEdit: (range: NSRange, replacement: String, replaced: String)?
    private var checkboxes: [UUID: NSButton] = [:]

    /// Replaces the checklist without making it an undo step. Used for saved state from the model.
    func setChecklist(_ newValue: ChecklistSidecar?) {
        checklist = newValue
        refreshChecklistControls()
    }

    // MARK: - Tracking edits

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, let replacementString, isRichText {
            let replaced = (string as NSString).substring(with: affectedCharRange)
            pendingEdit = (affectedCharRange, replacementString, replaced)
        } else {
            pendingEdit = nil
        }
        return allowed
    }

    override func didChangeText() {
        let isRestoringUndo = (undoManager?.isUndoing ?? false) || (undoManager?.isRedoing ?? false)
        if let edit = pendingEdit, !isRestoringUndo {
            // The text has already changed. Rebuild the text as it was, so the transform sees both sides of the edit.
            let current = string as NSString
            let insertedLength = (edit.replacement as NSString).length
            let oldText = current.replacingCharacters(
                in: NSRange(location: edit.range.location, length: insertedLength),
                with: edit.replaced
            )
            let updated = ChecklistEditing.apply(
                checklist,
                oldText: oldText as NSString,
                range: edit.range,
                replacement: edit.replacement,
                makeID: UUID.init
            )
            setChecklistRegisteringUndo(updated)
        }
        pendingEdit = nil
        super.didChangeText()
        refreshChecklistControls()
        reportRichEdit()
    }

    /// Replaces the checklist and registers the change for undo. Undo and redo come back through this same method.
    private func setChecklistRegisteringUndo(_ newValue: ChecklistSidecar?) {
        let previous = checklist
        guard previous != newValue else { return }
        checklist = newValue
        undoManager?.registerUndo(withTarget: self) { target in
            target.setChecklistRegisteringUndo(previous)
            target.refreshChecklistControls()
            target.reportRichEdit()
        }
        refreshChecklistControls()
    }

    private func reportRichEdit() {
        guard isRichText, let onRichEdit else { return }
        onRichEdit(attributedString(), checklist)
    }

    // MARK: - Formatting commands

    @objc func toggleBold(_ sender: Any?) {
        toggleFontTrait(.boldFontMask)
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggleFontTrait(.italicFontMask)
    }

    @objc func toggleUnderline(_ sender: Any?) {
        guard enableRichText() else { return }
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage else {
            // With no selection, the next typed text takes the new underline state.
            let isOn = typingAttributes[.underlineStyle] != nil
            typingAttributes[.underlineStyle] = isOn ? nil : NSUnderlineStyle.single.rawValue
            return
        }
        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        let isOn = (storage.attribute(.underlineStyle, at: selection.location, effectiveRange: nil) as? Int ?? 0) != 0
        storage.beginEditing()
        if isOn {
            storage.removeAttribute(.underlineStyle, range: selection)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selection)
        }
        storage.endEditing()
        didChangeText()
    }

    @objc func applyHeading1(_ sender: Any?) {
        applyFont(size: 26, bold: true)
    }

    @objc func applyHeading2(_ sender: Any?) {
        applyFont(size: 20, bold: true)
    }

    @objc func applyHeading3(_ sender: Any?) {
        applyFont(size: 16, bold: true)
    }

    @objc func applyBodyText(_ sender: Any?) {
        applyFont(size: NSFont.preferredFont(forTextStyle: .body).pointSize, bold: false)
    }

    /// Toggles a bullet on every paragraph the selection touches. Undo is registered through the text system.
    @objc func toggleBulletList(_ sender: Any?) {
        guard enableRichText(), let storage = textStorage else { return }
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let isBulleted = style.textLists.contains { $0.markerFormat == .disc }
            if isBulleted {
                style.textLists = []
                style.headIndent = 0
                style.firstLineHeadIndent = 0
            } else {
                style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
                style.headIndent = 24
                style.firstLineHeadIndent = 0
            }
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Adds a checklist item to each paragraph the selection touches, or removes them when all already have one.
    @objc func toggleChecklist(_ sender: Any?) {
        guard enableRichText() else { return }
        let text = string as NSString
        let selection = selectedRange()
        let indices = ChecklistEditing.paragraphIndices(in: text, covering: selection)
        let paragraphs = ChecklistEditing.paragraphRanges(in: text)
        let allHaveItems = indices.allSatisfy { index in
            checklist?.items.contains { $0.location == paragraphs[index].location } ?? false
        }
        if allHaveItems {
            setChecklistRegisteringUndo(ChecklistEditing.removingItems(from: checklist, in: text, covering: selection))
        } else {
            setChecklistRegisteringUndo(
                ChecklistEditing.addingItems(to: checklist, in: text, covering: selection, makeID: UUID.init)
            )
        }
        reportRichEdit()
    }

    /// Checks or unchecks the checklist item on the paragraph at the insertion point. Does nothing when there is none.
    @objc func toggleCheckedItem(_ sender: Any?) {
        guard isRichText, let item = ChecklistEditing.item(at: selectedRange().location, in: checklist, text: string as NSString) else {
            return
        }
        setChecklistRegisteringUndo(ChecklistEditing.toggled(checklist, itemID: item.id))
        reportRichEdit()
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        setChecklistRegisteringUndo(ChecklistEditing.toggled(checklist, itemID: id))
        reportRichEdit()
    }

    // MARK: - Checkbox controls

    /// Keeps one checkbox beside each checklist item. The boxes are real controls, so VoiceOver and the keyboard reach them.
    /// The checklist paragraphs get a left indent so the boxes never cover text.
    func refreshChecklistControls() {
        guard isRichText, let layoutManager, let textContainer else {
            removeCheckboxes(keeping: [])
            return
        }
        let text = string as NSString
        let items = checklist?.items ?? []
        // Laying out the whole text is only needed to place boxes, so notes without items skip it on every keystroke.
        if !items.isEmpty {
            layoutManager.ensureLayout(for: textContainer)
        }
        applyChecklistIndent(in: text)

        for item in items {
            let button = checkboxes[item.id] ?? makeCheckbox(for: item.id)
            let wanted: NSControl.StateValue = item.isChecked ? .on : .off
            if button.state != wanted {
                button.state = wanted
            }
            let snippet = String(text.substring(with: NSRange(location: item.location, length: item.length)).prefix(60))
            button.setAccessibilityLabel(snippet.isEmpty ? "Checklist item" : "Checklist item, \(snippet)")

            let line = lineRect(forCharacterAt: item.location)
            let origin = textContainerOrigin
            let frame = NSRect(x: origin.x + 2, y: origin.y + line.midY - 8, width: 16, height: 16)
            if button.frame != frame {
                button.frame = frame
            }
        }
        removeCheckboxes(keeping: Set(items.map(\.id)))
    }

    private func makeCheckbox(for id: UUID) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        button.setAccessibilityIdentifier("checklistItem")
        addSubview(button)
        checkboxes[id] = button
        return button
    }

    private func removeCheckboxes(keeping live: Set<UUID>) {
        for (id, button) in checkboxes where !live.contains(id) {
            button.removeFromSuperview()
            checkboxes[id] = nil
        }
    }

    private func applyChecklistIndent(in text: NSString) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let items = Set((checklist?.items ?? []).map(\.location))
        for paragraph in ChecklistEditing.paragraphRanges(in: text) {
            let range = text.paragraphRange(for: NSRange(location: paragraph.location, length: 0))
            guard range.location < storage.length else { continue }
            let indent: CGFloat = items.contains(paragraph.location) ? 24 : 0
            let current = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            guard current?.headIndent != indent || current?.firstLineHeadIndent != indent else { continue }
            let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// The line fragment that holds `location`, in text view coordinates. An empty last line uses the extra fragment.
    private func lineRect(forCharacterAt location: Int) -> NSRect {
        guard let layoutManager else { return .zero }
        let text = string as NSString
        if layoutManager.numberOfGlyphs == 0 || location >= text.length {
            return layoutManager.extraLineFragmentRect
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    override func layout() {
        super.layout()
        refreshChecklistControls()
    }

    /// The text system does not expose subviews to accessibility, so the checkboxes are listed as children explicitly.
    override func accessibilityChildren() -> [Any]? {
        let boxes = checkboxes.values.sorted { $0.frame.minY < $1.frame.minY }
        return (super.accessibilityChildren() ?? []) + boxes
    }

    // MARK: - Shared helpers

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard enableRichText() else { return }
        let manager = NSFontManager.shared
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage else {
            let current = typingAttributes[.font] as? NSFont ?? font ?? .preferredFont(forTextStyle: .body)
            let hasTrait = manager.traits(of: current).contains(trait)
            typingAttributes[.font] = hasTrait
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            return
        }
        guard shouldChangeText(in: selection, replacementString: nil) else { return }
        let firstFont = storage.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont ?? .preferredFont(forTextStyle: .body)
        let remove = manager.traits(of: firstFont).contains(trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selection) { value, subrange, _ in
            let current = value as? NSFont ?? .preferredFont(forTextStyle: .body)
            let converted = remove
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Sets the size, and bold, on every paragraph the selection touches and keeps italic and underline.
    private func applyFont(size: CGFloat, bold: Bool) {
        guard enableRichText(), let storage = textStorage else { return }
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        let manager = NSFontManager.shared
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = value as? NSFont ?? .preferredFont(forTextStyle: .body)
            var font = manager.convert(current, toSize: size)
            font = bold
                ? manager.convert(font, toHaveTrait: .boldFontMask)
                : manager.convert(font, toNotHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: font, range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Switches a plain note to formatted before a command runs. Returns false when the note cannot be edited.
    private func enableRichText() -> Bool {
        guard isEditable else { return false }
        if !isRichText {
            isRichText = true
            onRichTextRequested?(attributedString())
        }
        return true
    }
}
