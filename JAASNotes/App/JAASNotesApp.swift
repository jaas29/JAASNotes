import SwiftUI

@main
struct JAASNotesApp: App {
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryShellView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    Task { await model.createNote() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.phase != .ready)
            }
        }
    }
}
