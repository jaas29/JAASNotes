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

    /// Asks for a destination, then writes the recovery copy. Failures appear through the model's operation error.
    static func saveRecoveryCopy(model: LibraryModel) {
        guard let url = chooseRecoveryDestination() else { return }
        model.saveRecoveryCopy(to: url)
    }
}
