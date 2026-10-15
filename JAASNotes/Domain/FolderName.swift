import Foundation

/// Folder-name rules. Names are trimmed and stored with their display spelling; uniqueness uses a normalized key.
enum FolderName {
    /// Names of virtual queries (All Notes, Recently Deleted). These cannot be used for real folders.
    static let reservedDisplayNames = ["All Notes", "Recently Deleted"]

    /// Validates user input and returns the spelling to store plus the key used for uniqueness.
    static func validated(_ input: String) throws -> (displayName: String, normalizedName: String) {
        let displayName = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { throw LibraryError.emptyFolderName }

        let normalizedName = normalize(displayName)
        let reservedNames = Set(reservedDisplayNames.map(normalize))
        guard !reservedNames.contains(normalizedName) else { throw LibraryError.reservedFolderName }

        return (displayName, normalizedName)
    }

    /// Case- and diacritic-insensitive key. Canonically equivalent spellings produce the same key.
    static func normalize(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}
