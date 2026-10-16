import AppKit
import SwiftUI

/// Note rows for the current sidebar selection. Titles and previews show in-memory drafts, so typing is visible here.
struct NoteListView: View {
    @Bindable var model: LibraryModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        List(selection: Binding(
            get: { model.selectedNoteID },
            set: { noteID in Task { await model.requestNoteSelection(noteID) } }
        )) {
            ForEach(model.listedNotes) { note in
                let draft = model.draft(for: note)
                NoteRow(
                    title: draft.title,
                    bodyPreview: draft.bodyPlainText,
                    date: note.deletedAt ?? note.modifiedAt,
                    dateLabel: note.deletedAt == nil ? nil : "Deleted"
                )
                .tag(note.id)
                .contextMenu {
                    if note.deletedAt == nil {
                        moveMenu(for: note)
                        Divider()
                        Button("Move to Recently Deleted", role: .destructive) {
                            Task { await model.trashNote(note.id) }
                        }
                    } else {
                        Button("Restore") {
                            Task { await model.restoreNote(note.id) }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.listedNotes.isEmpty {
                emptyState
            }
        }
        .searchable(
            text: Binding(get: { model.searchText }, set: { model.setSearchText($0) }),
            prompt: "Search Notes"
        )
        .modifier(SearchFocusBinding(isFocused: $isSearchFocused))
        .onChange(of: model.searchFocusRequested) { _, requested in
            guard requested else { return }
            model.searchFocusRequested = false
            if #available(macOS 15.0, *) {
                isSearchFocused = true
            } else {
                SearchFieldFocus.focus()
            }
        }
        .searchScopes(Binding(get: { model.searchScope }, set: { model.searchScope = $0 })) {
            Text("All Notes").tag(LibraryModel.SearchScope.allNotes)
            Text("This Folder").tag(LibraryModel.SearchScope.currentFolder)
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
            ToolbarItem {
                Menu {
                    if let note = model.selectedNote {
                        moveMenu(for: note)
                    }
                } label: {
                    Label("Move To", systemImage: "folder")
                }
                .help("Move the selected note to a folder")
                .disabled(model.selectedNote == nil || model.isShowingRecentlyDeleted)
                .accessibilityLabel("Move To")
                .accessibilityIdentifier("moveToMenu")
            }
            ToolbarItem {
                if model.isShowingRecentlyDeleted {
                    Button {
                        if let id = model.selectedNoteID {
                            Task { await model.restoreNote(id) }
                        }
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .help("Restore the selected note")
                    .disabled(model.selectedNote == nil)
                    .accessibilityIdentifier("toolbarRestore")
                } else {
                    Button {
                        if let id = model.selectedNoteID {
                            Task { await model.trashNote(id) }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Move the selected note to Recently Deleted")
                    .disabled(model.selectedNote == nil)
                    .accessibilityIdentifier("toolbarDelete")
                }
            }
        }
        .accessibilityIdentifier("noteList")
    }
}

extension NoteListView {
    /// Folder choices for one note. The note's current folder is shown but disabled.
    @ViewBuilder
    fileprivate func moveMenu(for note: NoteSnapshot) -> some View {
        ForEach(model.folders) { folder in
            Button(folder.name) {
                Task { await model.moveNote(note.id, toFolder: folder.id) }
            }
            .disabled(folder.id == note.folderID)
        }
    }

    @ViewBuilder
    fileprivate var emptyState: some View {
        if model.isSearching {
            ContentUnavailableView.search(text: model.searchText)
        } else if case .folder = model.sidebarSelection {
            ContentUnavailableView {
                Label("No Notes in This Folder", systemImage: "folder")
            } description: {
                Text("New notes you create here appear in this folder.")
            } actions: {
                Button("New Note") {
                    Task { await model.createNote() }
                }
            }
        } else {
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
}

/// `searchFocused` is macOS 15 API. The deployment target is macOS 14, so older systems use `SearchFieldFocus`.
private struct SearchFocusBinding: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(isFocused)
        } else {
            content
        }
    }
}

/// Moves keyboard focus to the window's search field on macOS 14, where SwiftUI cannot target it directly.
@MainActor
enum SearchFieldFocus {
    static func focus() {
        guard let window = NSApp.keyWindow else { return }
        let toolbarViews = window.toolbar?.items.compactMap(\.view) ?? []
        let candidates = toolbarViews + [window.contentView].compactMap { $0 }
        for candidate in candidates {
            if let field = firstSearchField(in: candidate) {
                window.makeFirstResponder(field)
                return
            }
        }
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField {
            return field
        }
        for subview in view.subviews {
            if let field = firstSearchField(in: subview) {
                return field
            }
        }
        return nil
    }
}

private struct NoteRow: View {
    let title: String
    let bodyPreview: String
    let date: Date
    let dateLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.isEmpty ? "Untitled Note" : title)
                .font(.headline)
                .lineLimit(1)
            Text(bodyPreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("noteRow")
    }

    private var dateText: String {
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return dateLabel.map { "\($0) \(formatted)" } ?? formatted
    }
}
