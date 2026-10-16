import SwiftUI

/// Settings window (Cmd-comma): list order, backup status, and privacy.
struct SettingsView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Form {
            Section("Notes") {
                Picker("Sort notes by", selection: $model.sortOrder) {
                    ForEach(NoteSortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                Text("Pinned notes always appear first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backups") {
                if let last = model.lastBackupDate {
                    LabeledContent("Last backup") {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    LabeledContent("Last backup") {
                        Text("None yet")
                    }
                }
                HStack {
                    Button("Back Up Now") {
                        Task { await model.backUpNow() }
                    }
                    .disabled(model.isLibraryLocked || model.phase != .ready)
                    Button("Manage Backups…") {
                        model.backupsSheetRequested = true
                    }
                    .disabled(model.phase != .ready)
                }
                Text("An automatic backup is made at most once a day after changes. The newest seven are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = model.backupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Text("Your notes stay on this Mac. JAASNotes makes no network connections and has no accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }
}
