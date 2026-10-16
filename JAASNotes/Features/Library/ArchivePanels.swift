import AppKit

/// Native panels and the import review for archives and text files. Each action is a menu command, so it is reachable by keyboard.
@MainActor
enum ArchivePanels {
    static func exportArchive(model: LibraryModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JAASNotes Archive.jnarchive"
        panel.message = "Choose a name for the archive folder. It must not already exist."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportArchive(to: url) }
    }

    static func importArchive(model: LibraryModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a JAASNotes archive folder to import. Its notes are added as new notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let review = await model.reviewArchive(at: url) else { return }
            guard confirmImport(review) else { return }
            await model.importArchive(review)
        }
    }

    static func importTextFile(model: LibraryModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a plain text or RTF file. It is added as a new note."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if url.pathExtension.lowercased() == "rtf" {
                await model.importRTFFile(at: url)
            } else {
                await model.importTextFile(at: url)
            }
        }
    }

    static func exportNote(model: LibraryModel, note: NoteSnapshot, asRTF: Bool) {
        let panel = NSSavePanel()
        let base = note.title.isEmpty ? "Untitled Note" : note.title
        panel.nameFieldStringValue = asRTF ? "\(base).rtf" : "\(base).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportNote(note, asRTF: asRTF, to: url) }
    }

    /// Shows what the import will create before it is written. Names are shown exactly as they will be stored.
    private static func confirmImport(_ review: ArchiveService.Validated) -> Bool {
        let counts = review.manifest.counts
        var lines = [
            "\(counts.notes) notes, \(counts.folders) folders, and \(counts.attachments) attachments will be added as new items.",
            "Nothing that is already in your library will be changed.",
        ]
        for rename in review.renamedFolders {
            lines.append("The folder \u{201C}\(rename.original)\u{201D} will be added as \u{201C}\(rename.final)\u{201D}, because that name is already used.")
        }
        let alert = NSAlert()
        alert.messageText = "Import this archive?"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
