import AppKit
import UniformTypeIdentifiers

/// System save panel for a recovery copy. Writing and verifying the file is done by the model.
@MainActor
enum RecoveryPanels {
    static func chooseRecoveryDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Recovery Copy"
        panel.message = "Unsaved notes will be written to this file so they can be recovered later."
        panel.nameFieldStringValue = "JAASNotes Recovery.jaasnotes-recovery.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseBackupFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Copy Backup"
        panel.message = "Choose a folder. The complete backup package is copied into it."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDiagnosticDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Info"
        panel.message = "This file lists versions, file sizes, and backup counts. It does not contain note text."
        panel.nameFieldStringValue = "JAASNotes Diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveDiagnosticInfo(model: LibraryModel) {
        guard let url = chooseDiagnosticDestination() else { return }
        model.saveDiagnosticInfo(to: url)
    }

    /// Asks for a destination, then writes the recovery copy. Failures appear through the model's operation error.
    static func saveRecoveryCopy(model: LibraryModel) {
        guard let url = chooseRecoveryDestination() else { return }
        model.saveRecoveryCopy(to: url)
    }
}
