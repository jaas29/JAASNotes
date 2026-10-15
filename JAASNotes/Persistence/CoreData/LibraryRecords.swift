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
    @NSManaged var folder: FolderRecord?
}
