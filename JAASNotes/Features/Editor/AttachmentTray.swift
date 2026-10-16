import AppKit
import SwiftUI

/// Files attached to one note, below its text. Every action is a real button, so the keyboard and VoiceOver reach it.
/// Trashed and unreadable notes show their files read-only: they can be opened and saved, but not changed.
struct AttachmentTray: View {
    let model: LibraryModel
    let note: NoteSnapshot
    let isReadOnly: Bool

    @State private var pendingRemoval: AttachmentSnapshot?

    var body: some View {
        let rows = model.attachments(for: note.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(rows.isEmpty ? "No attachments" : "Attachments (\(rows.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("attachmentCount")
                Spacer()
                if !isReadOnly {
                    Button("Attach File…") {
                        AttachmentPanels.chooseFile(model: model, noteID: note.id)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("attachFile")
                }
            }

            if !rows.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(rows) { attachment in
                            AttachmentChip(
                                model: model,
                                attachment: attachment,
                                isMissing: model.missingAttachmentIDs.contains(attachment.id),
                                isReadOnly: isReadOnly,
                                onRemove: { pendingRemoval = attachment }
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task(id: note.id) {
            await model.loadAttachments(for: note.id)
        }
        .confirmationDialog(
            "Remove this attachment?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Attachment", role: .destructive) {
                if let attachment = pendingRemoval {
                    Task { await model.removeAttachment(attachment.id, from: note.id) }
                }
                pendingRemoval = nil
            }
            Button("Keep", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("The file is removed from this note. The original file on your Mac is not changed.")
        }
    }
}

/// One attached file: a preview for images, its name and size, and its actions.
private struct AttachmentChip: View {
    let model: LibraryModel
    let attachment: AttachmentSnapshot
    let isMissing: Bool
    let isReadOnly: Bool
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail, !isMissing {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: isMissing ? "exclamationmark.triangle" : "doc")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.originalFilename)
                    .font(.callout)
                    .lineLimit(1)
                Text(isMissing ? "File missing" : ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(isMissing ? .primary : .secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)

            Button("Open") {
                model.openAttachment(attachment)
            }
            .disabled(isMissing)
            .accessibilityLabel("Open \(attachment.originalFilename)")

            Button("Save Copy…") {
                AttachmentPanels.saveCopy(model: model, attachment: attachment)
            }
            .disabled(isMissing)
            .accessibilityLabel("Save a copy of \(attachment.originalFilename)")

            if !isReadOnly {
                Button("Remove", role: .destructive, action: onRemove)
                    .accessibilityLabel("Remove \(attachment.originalFilename)")
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentRow")
        .task(id: attachment.id) {
            guard !isMissing, attachment.contentType.hasPrefix("image/"),
                  let url = model.attachmentFileURL(for: attachment)
            else { return }
            thumbnail = NSImage(contentsOf: url)
        }
    }
}

/// Native file panels for attaching and saving copies. Only the chosen file is read, and only it is copied.
@MainActor
enum AttachmentPanels {
    static func chooseFile(model: LibraryModel, noteID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to attach. JAASNotes keeps its own copy."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.attachFile(at: url, to: noteID) }
    }

    static func saveCopy(model: LibraryModel, attachment: AttachmentSnapshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.originalFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportAttachment(attachment, to: url)
    }
}
