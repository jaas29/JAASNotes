import SwiftUI

/// Title field, plain-text body, and a save status line for one note. The caller applies `.id(note.id)`, so
/// switching notes starts a fresh editor with its own undo history.
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

            SaveStatusLine(model: model, status: model.saveStatus(for: note.id))
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

/// Shows the save state. When a save has failed, it also offers Retry, recovery copy, and discard.
private struct SaveStatusLine: View {
    let model: LibraryModel
    let status: LibraryModel.SaveStatus

    @State private var isConfirmingDiscard = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(isFailed ? .primary : .secondary)
                .accessibilityIdentifier("saveStatus")

            Spacer()

            if isFailed {
                Button("Retry") {
                    Task { await model.retrySave() }
                }
                Button("Save Recovery Copy…") {
                    RecoveryPanels.saveRecoveryCopy(model: model)
                }
                Button("Discard…") {
                    isConfirmingDiscard = true
                }
                .accessibilityIdentifier("discardUnsaved")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                model.discardUnsavedChanges()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Text that has not been saved will be removed. This cannot be undone.")
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var label: String {
        switch status {
        case .saved: "Saved"
        case .unsaved: "Unsaved changes"
        case .saving: "Saving…"
        case .failed: "Not saved"
        }
    }
}
