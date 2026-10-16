import SwiftUI

/// Shown instead of the editor when the library cannot be opened. Nothing here deletes library data.
struct StoreRecoveryView: View {
    let model: LibraryModel
    @State private var isShowingBackups = false
    @State private var isConfirmingNewLibrary = false

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Library Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(model.phaseFailureMessage ?? "The library could not be opened.") Nothing was deleted.")
            } actions: {
                Button("Retry") {
                    Task { await model.retryOpening() }
                }
                .keyboardShortcut(.defaultAction)

                Button("Restore From Backup…") {
                    isShowingBackups = true
                }

                Button("Save Diagnostic Info…") {
                    RecoveryPanels.saveDiagnosticInfo(model: model)
                }

                Button("Create New Library…", role: .destructive) {
                    isConfirmingNewLibrary = true
                }
            }

            if let message = model.backupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .accessibilityIdentifier("libraryFailure")
        .sheet(isPresented: $isShowingBackups) {
            BackupsSheet(model: model)
        }
        .confirmationDialog(
            "Create a new library?",
            isPresented: $isConfirmingNewLibrary,
            titleVisibility: .visible
        ) {
            Button("Create New Library", role: .destructive) {
                Task { await model.createNewLibraryPreservingExisting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current library folder is moved into the Recovery folder inside JAASNotes' data folder. It is kept, not deleted.")
        }
    }
}

/// Lists valid backups, takes a manual backup, and restores one after confirmation.
struct BackupsSheet: View {
    let model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRestore: BackupSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backups")
                .font(.title2.weight(.semibold))

            if let last = model.lastBackupDate {
                Text("Last backup: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lastBackup")
            } else {
                Text("No backups yet.")
                    .foregroundStyle(.secondary)
            }

            if let message = model.backupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("backupMessage")
            }

            List(model.backups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("\(Self.label(for: backup.kind)) · \(backup.counts.activeNotes) notes · \(backup.counts.deletedNotes) in Recently Deleted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy…") {
                        if let folder = RecoveryPanels.chooseBackupFolder() {
                            model.exportBackup(backup, to: folder)
                        }
                    }
                    .accessibilityIdentifier("copyBackup")
                    Button("Restore…") {
                        pendingRestore = backup
                    }
                    .disabled(model.isLibraryLocked)
                }
            }

            HStack {
                Button("Back Up Now") {
                    Task { await model.backUpNow() }
                }
                .disabled(model.isLibraryLocked || model.phase != .ready)
                .accessibilityIdentifier("backUpNow")

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
        .onAppear {
            model.refreshBackups()
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { backup in
            Button("Restore Backup", role: .destructive) {
                Task { await model.restoreBackup(backup) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("Your current library will be replaced with the backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)). The current library is backed up first if it can be read, and the previous library is kept in Recovery.")
        }
    }

    private static func label(for kind: BackupKind) -> String {
        switch kind {
        case .automatic: "Automatic"
        case .manual: "Manual"
        case .preRestore: "Before restore"
        }
    }
}
