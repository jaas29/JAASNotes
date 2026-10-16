import SwiftUI

/// Title field, note body, and a save status line for one note. The caller applies `.id(note.id)`, so switching
/// notes starts a fresh editor with its own undo history.
struct NoteEditorView: View {
    let model: LibraryModel
    let note: NoteSnapshot

    @FocusState private var isTitleFocused: Bool

    /// Trashed notes are shown read-only, with Restore instead of save controls.
    private var isReadOnly: Bool {
        note.deletedAt != nil
    }

    var body: some View {
        let draft = model.draft(for: note)
        let state = model.bodyState(for: note)
        let isUnreadable: Bool = {
            if case .unreadable = state { return true }
            return false
        }()

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
            .disabled(isReadOnly || isUnreadable)
            .accessibilityIdentifier("noteTitle")

            switch state {
            case .loading:
                ProgressView("Loading note…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("noteLoading")

            case .ready:
                NoteBodyEditor(
                    plainText: draft.bodyPlainText,
                    richText: draft.rich?.text,
                    checklist: draft.rich?.checklist,
                    isEditable: !isReadOnly,
                    onPlainChange: { model.updateDraft(for: note.id, body: $0) },
                    onRichChange: { model.updateRichDraft(for: note.id, text: $0, checklist: $1) },
                    onRichTextRequested: { model.updateRichDraft(for: note.id, text: $0, checklist: nil) }
                )

            case .unreadable(let fallbackText, let reason):
                UnreadableBanner(model: model, noteID: note.id, reason: reason)
                // The saved text is shown so it can be read and copied. Editing would overwrite the damaged original.
                NoteBodyEditor(
                    plainText: fallbackText,
                    richText: nil,
                    isEditable: false,
                    onPlainChange: { _ in },
                    onRichChange: { _, _ in },
                    onRichTextRequested: { _ in }
                )
            }

            AttachmentTray(model: model, note: note, isReadOnly: isReadOnly || isUnreadable)

            if let deletedAt = note.deletedAt {
                TrashStatusLine(model: model, noteID: note.id, deletedAt: deletedAt)
            } else if !isUnreadable {
                SaveStatusLine(model: model, status: model.saveStatus(for: note.id))
            }
        }
        .task(id: note.id) {
            await model.prepareBody(for: note)
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

/// Explains a note whose formatting could not be read. The saved text stays visible and read-only; a recovery copy keeps it editable.
private struct UnreadableBanner: View {
    let model: LibraryModel
    let noteID: UUID
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("This note's formatting could not be read, so it is shown as saved text and cannot be edited.")
                    .font(.callout)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Make Recovery Copy") {
                Task { await model.makeRecoveryCopy(for: noteID) }
            }
            .controlSize(.small)
            .accessibilityIdentifier("makeRecoveryCopy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
        .accessibilityIdentifier("unreadableBanner")
    }
}

/// Explains a trashed note and offers Restore. Its content is read-only until it is restored.
private struct TrashStatusLine: View {
    let model: LibraryModel
    let noteID: UUID
    let deletedAt: Date

    var body: some View {
        HStack(spacing: 8) {
            Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened)). Read-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("trashStatus")

            Spacer()

            Button("Restore") {
                Task { await model.restoreNote(noteID) }
            }
            .accessibilityIdentifier("restoreNote")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
