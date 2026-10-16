import AppKit
import SwiftUI

@main
struct JAASNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LibraryShellView(model: appDelegate.model)
        }
        Settings {
            SettingsView(model: appDelegate.model)
        }
        .commands {
            let model = appDelegate.model

            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    Task { await model.createNote() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.phase != .ready)

                Button("New Folder") {
                    model.folderSheetRequest = .create
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.phase != .ready)
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button(model.selectedNote?.isPinned == true ? "Unpin Note" : "Pin Note") {
                    if let note = model.selectedNote {
                        Task { await model.setPinned(note.id, !note.isPinned) }
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.selectedNote == nil || model.isShowingRecentlyDeleted)

                Button("Rename Folder…") {
                    if case .folder(let folderID) = model.sidebarSelection {
                        model.folderSheetRequest = .rename(folderID)
                    }
                }
                .disabled(!isUserFolderSelected(model))

                Menu("Move Note To") {
                    ForEach(model.folders) { folder in
                        Button(folder.name) {
                            if let noteID = model.selectedNoteID {
                                Task { await model.moveNote(noteID, toFolder: folder.id) }
                            }
                        }
                        .disabled(model.selectedNote?.folderID == folder.id)
                    }
                }
                .disabled(model.selectedNote == nil || model.isShowingRecentlyDeleted)

                Button("Move to Recently Deleted") {
                    trashSelectedNote(model)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedNote == nil || model.isShowingRecentlyDeleted)

                Button("Restore Note") {
                    if let noteID = model.selectedNoteID {
                        Task { await model.restoreNote(noteID) }
                    }
                }
                .disabled(!model.isShowingRecentlyDeleted || model.selectedNote == nil)

                Divider()

                Button("Backups…") {
                    model.backupsSheetRequested = true
                }
                .disabled(model.phase != .ready)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task { await model.flushPendingDrafts() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.phase != .ready)
            }

            CommandGroup(after: .textEditing) {
                Button("Find in Note…") {
                    // The native text finder handles Find in the focused text view.
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Search Notes") {
                    model.searchFocusRequested = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.phase != .ready)
            }

            CommandMenu("Format") {
                Button("Bold") {
                    NSApp.sendAction(#selector(NoteTextView.toggleBold(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    NSApp.sendAction(#selector(NoteTextView.toggleItalic(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Underline") {
                    NSApp.sendAction(#selector(NoteTextView.toggleUnderline(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("u", modifiers: .command)

                Divider()

                Button("Heading 1") {
                    NSApp.sendAction(#selector(NoteTextView.applyHeading1(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Heading 2") {
                    NSApp.sendAction(#selector(NoteTextView.applyHeading2(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Heading 3") {
                    NSApp.sendAction(#selector(NoteTextView.applyHeading3(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("3", modifiers: [.command, .option])

                Button("Body Text") {
                    NSApp.sendAction(#selector(NoteTextView.applyBodyText(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])

                Divider()

                Button("Bulleted List") {
                    NSApp.sendAction(#selector(NoteTextView.toggleBulletList(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Checklist") {
                    NSApp.sendAction(#selector(NoteTextView.toggleChecklist(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Check or Uncheck Item") {
                    NSApp.sendAction(#selector(NoteTextView.toggleCheckedItem(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Menu("Sort Notes By") {
                    ForEach(NoteSortOrder.allCases, id: \.self) { order in
                        Button(order.title) {
                            model.sortOrder = order
                        }
                    }
                }
                .disabled(model.phase != .ready)

                Button("All Notes") {
                    Task { await model.requestSidebarSelection(.allNotes) }
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(model.phase != .ready)

                Button("Recently Deleted") {
                    Task { await model.requestSidebarSelection(.recentlyDeleted) }
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(model.phase != .ready)
            }
        }
    }

    private func isUserFolderSelected(_ model: LibraryModel) -> Bool {
        guard case .folder(let folderID) = model.sidebarSelection else { return false }
        return model.folders.first { $0.id == folderID }.map { !$0.isDefault } ?? false
    }

    /// Cmd-Delete belongs to the text when the caret is in a text field. Only the note list gets the trash action.
    @MainActor
    private func trashSelectedNote(_ model: LibraryModel) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            return
        }
        guard let noteID = model.selectedNoteID else { return }
        Task { await model.trashNote(noteID) }
    }
}
