import SwiftUI

/// Three-column shell: folders, note list, and editor. Opening the library happens when the window appears.
struct LibraryShellView: View {
    @Bindable var model: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentSaveFailure = false
    @State private var folderSheet: FolderNameSheet.Mode?
    @State private var isShowingBackups = false
    @State private var folderToDelete: FolderSnapshot?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Opening Library")
            case .failed:
                StoreRecoveryView(model: model)
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
            } else {
                // A changed library gets at most one automatic backup a day.
                Task { await model.performAutomaticBackupIfDue() }
            }
        }
        .onDisappear {
            Task { await model.flushPendingDrafts() }
        }
        .onChange(of: model.backupsSheetRequested) { _, requested in
            guard requested else { return }
            model.backupsSheetRequested = false
            isShowingBackups = true
        }
        .onChange(of: model.folderSheetRequest) { _, request in
            guard let request else { return }
            model.folderSheetRequest = nil
            switch request {
            case .create:
                folderSheet = .create
            case .rename(let folderID):
                if let folder = model.folders.first(where: { $0.id == folderID }), !folder.isDefault {
                    folderSheet = .rename(folder)
                }
            }
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
                    .badge(model.notes.count)
                    .tag(LibraryModel.SidebarSelection.allNotes)

                Label("Recently Deleted", systemImage: "trash")
                    .badge(model.deletedNotes.count)
                    .tag(LibraryModel.SidebarSelection.recentlyDeleted)
                    .accessibilityIdentifier("recentlyDeletedItem")

                Section("Folders") {
                    ForEach(model.folders) { folder in
                        Label(folder.name, systemImage: folder.isDefault ? "tray" : "folder")
                            .badge(model.noteCount(inFolder: folder.id))
                            .tag(LibraryModel.SidebarSelection.folder(folder.id))
                            .contextMenu {
                                Button("Rename Folder…") {
                                    folderSheet = .rename(folder)
                                }
                                .disabled(folder.isDefault)
                                Button("Delete Folder…", role: .destructive) {
                                    folderToDelete = folder
                                }
                                .disabled(folder.isDefault)
                            }
                    }
                }
            }
            .navigationTitle("Folders")
            .accessibilityIdentifier("sidebar")
            .sheet(item: $folderSheet) { mode in
                FolderNameSheet(model: model, mode: mode)
            }
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
        .toolbar {
            ToolbarItem {
                Button {
                    folderSheet = .create
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("New Folder")
                .disabled(model.phase != .ready)
                .accessibilityIdentifier("newFolderButton")
            }
            ToolbarItem {
                Button {
                    isShowingBackups = true
                } label: {
                    Label("Backups", systemImage: "clock.arrow.circlepath")
                }
                .help("Back up or restore the library")
                .disabled(model.phase != .ready)
                .accessibilityIdentifier("backupsButton")
            }
        }
        .sheet(isPresented: $isShowingBackups) {
            BackupsSheet(model: model)
        }
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
            titleVisibility: .visible,
            presenting: folderToDelete
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                Task { await model.deleteFolder(folder.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("The notes in “\(folder.name)”, including those in Recently Deleted, move to Notes. No note is erased.")
        }
    }
}

/// Sheet for creating or renaming a folder. Invalid or duplicate names show an inline message and keep the sheet open.
struct FolderNameSheet: View {
    enum Mode: Identifiable {
        case create
        case rename(FolderSnapshot)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let folder): "rename-\(folder.id.uuidString)"
            }
        }
    }

    let model: LibraryModel
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    init(model: LibraryModel, mode: Mode) {
        self.model = model
        self.mode = mode
        if case .rename(let folder) = mode {
            _name = State(initialValue: folder.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .accessibilityIdentifier("folderNameField")

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("folderNameError")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var title: String {
        switch mode {
        case .create: "New Folder"
        case .rename: "Rename Folder"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .create: "Create"
        case .rename: "Rename"
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                switch mode {
                case .create:
                    try await model.createFolder(named: name)
                case .rename(let folder):
                    try await model.renameFolder(folder.id, to: name)
                }
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "The folder could not be saved."
            }
        }
    }
}
