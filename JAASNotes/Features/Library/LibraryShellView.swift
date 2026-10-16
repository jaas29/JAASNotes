import SwiftUI

/// Three-column shell: folders, note list, and editor. Opening the library happens when the window appears.
struct LibraryShellView: View {
    @Bindable var model: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentSaveFailure = false

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
        // Best-effort saves when the app leaves the foreground or the window goes away.
        // A failure stays visible in the editor and keeps the draft.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await model.flushPendingDrafts() }
            }
        }
        .onDisappear {
            Task { await model.flushPendingDrafts() }
        }
        .onChange(of: model.saveFailure) { _, failure in
            presentSaveFailure = failure != nil
        }
        .alert(
            "Changes Not Saved",
            isPresented: $presentSaveFailure
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(model.saveFailure ?? "")\n\nUse Retry or Save Recovery Copy in the note's status line.")
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
            List(selection: Binding(
                get: { model.sidebarSelection },
                set: { selection in Task { await model.requestSidebarSelection(selection) } }
            )) {
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
