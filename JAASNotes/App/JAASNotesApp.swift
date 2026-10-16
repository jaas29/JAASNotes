import SwiftUI

@main
struct JAASNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LibraryShellView(model: appDelegate.model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    Task { await appDelegate.model.createNote() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appDelegate.model.phase != .ready)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task { await appDelegate.model.flushPendingDrafts() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appDelegate.model.phase != .ready)
            }
        }
    }
}
