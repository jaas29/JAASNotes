import AppKit

/// Owns the library model so AppKit termination can wait for pending saves.
///
/// Ordinary Quit flushes first. If a save fails, Quit is cancelled and the window shows the failure with Retry,
/// Save Recovery Copy, and Discard. Showing a modal dialog during termination crashes, so the decision is made in the
/// window, and Quit can be chosen again once the text is saved or preserved.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else {
            return .terminateNow
        }
        let model = self.model
        Task { @MainActor in
            let saved = await model.flushPendingDrafts()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
