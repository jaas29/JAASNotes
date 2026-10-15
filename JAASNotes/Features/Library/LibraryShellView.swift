import SwiftUI

/// Three-column shell: folders, note list, and editor. Opening the library happens when the window appears.
struct LibraryShellView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Opening Library")
            case .failed(let message):
                ContentUnavailableView(
                    "Library Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .accessibilityIdentifier("libraryFailure")
            case .ready:
                splitView
            }
        }
        .task {
            await model.loadIfNeeded()
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.clearOperationError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.operationError ?? "")
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                Label("All Notes", systemImage: "note.text")
                    .tag(LibraryModel.SidebarSelection.allNotes)

                Section("Folders") {
                    ForEach(model.folders) { folder in
                        Label(folder.name, systemImage: folder.isDefault ? "tray" : "folder")
                            .tag(LibraryModel.SidebarSelection.folder(folder.id))
                    }
                }
            }
            .navigationTitle("Folders")
            .accessibilityIdentifier("sidebar")
        } content: {
            NoteListView(model: model)
        } detail: {
            if let note = model.selectedNote {
                NoteEditorView(model: model, note: note)
                    .id(note.id)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "square.and.pencil"
                )
                .accessibilityIdentifier("editor")
            }
        }
    }
}
