import CoreData
import Foundation

// Managed object classes for the version-1 model. Entity and class names must match the model file.

@objc(LibraryMetadataRecord)
final class LibraryMetadataRecord: NSManagedObject {
    @NSManaged var libraryID: UUID
    @NSManaged var createdAt: Date
    @NSManaged var formatVersion: Int32
}

@objc(FolderRecord)
final class FolderRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var normalizedName: String
    @NSManaged var createdAt: Date
    @NSManaged var modifiedAt: Date
    @NSManaged var isDefault: Bool
    @NSManaged var notes: NSSet?
}

@objc(NoteRecord)
final class NoteRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var bodyPlainText: String
    @NSManaged var createdAt: Date
    @NSManaged var modifiedAt: Date
    @NSManaged var deletedAt: Date?
    @NSManaged var revision: Int64
    /// Added in version 2. Existing version-1 notes migrate with `false`.
    @NSManaged var isPinned: Bool
    /// Added in version 3. 0 means plain text only; `RichNoteContent.formatVersion` means RTF and checklist data are present.
    @NSManaged var contentFormatVersion: Int32
    /// Added in version 3. RTF for the body, validated by `RichTextCodec` before it is stored.
    @NSManaged var richTextData: Data?
    /// Added in version 3. Versioned checklist sidecar, or nil when the note has no checklist.
    @NSManaged var checklistData: Data?
    @NSManaged var folder: FolderRecord?
}
