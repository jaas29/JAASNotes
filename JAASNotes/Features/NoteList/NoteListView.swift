import SwiftUI

/// Note rows for the current sidebar selection. Titles and previews show in-memory drafts, so typing is visible here.
struct NoteListView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.selectedNoteID) {
            ForEach(model.visibleNotes) { note in
                let draft = model.draft(for: note)
                NoteRow(title: draft.title, bodyPreview: draft.bodyPlainText, modifiedAt: note.modifiedAt)
                    .tag(note.id)
            }
        }
        .overlay {
            if model.visibleNotes.isEmpty {
                ContentUnavailableView {
                    Label("No Notes", systemImage: "note.text")
                } description: {
                    Text("Create a note to get started.")
                } actions: {
                    Button("New Note") {
                        Task { await model.createNote() }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.createNote() }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note")
                .disabled(model.phase != .ready)
            }
        }
        .accessibilityIdentifier("noteList")
    }
}

private struct NoteRow: View {
    let title: String
    let bodyPreview: String
    let modifiedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.isEmpty ? "Untitled Note" : title)
                .font(.headline)
                .lineLimit(1)
            Text(bodyPreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("noteRow")
    }
}
