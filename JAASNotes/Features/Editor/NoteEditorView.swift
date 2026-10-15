import SwiftUI

/// Title field and plain-text body for one note. The caller applies `.id(note.id)`, so switching notes starts
/// a fresh editor with its own undo history.
struct NoteEditorView: View {
    let model: LibraryModel
    let note: NoteSnapshot

    @FocusState private var isTitleFocused: Bool

    var body: some View {
        let draft = model.draft(for: note)

        VStack(alignment: .leading, spacing: 0) {
            TextField(
                "Untitled Note",
                text: Binding(
                    get: { draft.title },
                    set: { model.updateDraft(for: note.id, title: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.title.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .focused($isTitleFocused)
            .accessibilityIdentifier("noteTitle")

            PlainTextEditor(text: draft.bodyPlainText) { body in
                model.updateDraft(for: note.id, body: body)
            }
        }
        .task(id: note.id) {
            // Runs after the view is installed, so a freshly created note reliably takes focus.
            guard model.titleFocusRequest == note.id else { return }
            model.titleFocusRequest = nil
            // Let SwiftUI install the text field first; a focus request in the same update can be dropped.
            await Task.yield()
            isTitleFocused = true
        }
    }
}
