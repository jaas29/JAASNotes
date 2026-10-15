import SwiftUI

/// Placeholder three-column shell. Real folders, notes, and the editor arrive in later substages.
struct LibraryShellView: View {
    enum SidebarItem: Hashable {
        case allNotes
        case recentlyDeleted
    }

    @State private var selection: SidebarItem? = .allNotes

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Notes", systemImage: "note.text")
                    .tag(SidebarItem.allNotes)
                Label("Recently Deleted", systemImage: "trash")
                    .tag(SidebarItem.recentlyDeleted)
            }
            .navigationTitle("Folders")
            .accessibilityIdentifier("sidebar")
        } content: {
            ContentUnavailableView(
                "No Notes",
                systemImage: "note.text",
                description: Text("Notes will appear here.")
            )
            .accessibilityIdentifier("noteList")
        } detail: {
            ContentUnavailableView(
                "No Note Selected",
                systemImage: "square.and.pencil"
            )
            .accessibilityIdentifier("editor")
        }
    }
}
