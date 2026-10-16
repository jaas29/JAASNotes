# JAASNotes progress log

Each substage records what changed, the commands run, the environment, the result, and remaining risks. Status values: pass, fail, not run.

## 01-01 — Xcode project and sandboxed three-column shell

- **Status:** pass (complete)
- **Date:** 2026-10-15
- **Commit:** not committed yet (repository initialized; commit pending owner request)
- **Location:** `~/Developer/JAASNOTES` (moved from iCloud Desktop after the build issue below; see D-003)

### Environment

- Mac: Apple M3 Pro (arm64), macOS 26.6.2 (build 25G83)
- Xcode: 26.3 (build 17C529), Swift 6.2.4, SDK MacOSX26.2
- Deployment target: macOS 14.0 (`minos 14.0` verified in the built binary)
- Swift language mode: 5, with `SWIFT_STRICT_CONCURRENCY = complete`
- **Not tested:** macOS 14 Sonoma runtime. The app was built against the 14.0 deployment target and run only on macOS 26.6.2.
- **Verified after the move:** the plan's standard commands (`.build/DerivedData`, `.build/TestResults`) build and test successfully from `~/Developer/JAASNOTES`. Build output is gitignored.
- **Not tested:** Intel (x86_64). The build targets the local arm64 machine.

### Changes

- `git init` in `JAASNOTES/` (the folder was previously untracked inside a parent repository).
- `.gitignore`: build output, per-user Xcode state, `.DS_Store`, SQLite and WAL files, and local xcconfig overrides.
- `JAASNotes.xcodeproj`: hand-written `project.pbxproj` with three targets (`JAASNotes` app, `JAASNotesTests` unit tests, `JAASNotesUITests` UI tests) and a shared `JAASNotes` scheme.
- `JAASNotes/App/JAASNotesApp.swift`: app entry point.
- `JAASNotes/Features/Library/LibraryShellView.swift`: placeholder `NavigationSplitView` with sidebar, note-list, and editor placeholders. It has no store yet.
- `JAASNotes/Resources/JAASNotes.entitlements`: `com.apple.security.app-sandbox` only. No network entitlement.
- `JAASNotesTests/Unit/AppConfigurationTests.swift`: asserts the bundle identifier `org.jaasnotes.JAASNotes`.
- `JAASNotesUITests/LaunchUITests.swift`: launches the app and checks the shell's accessibility identifiers and placeholder labels.

### Commands run

Build (first run, while the project was on Desktop, used a cache path; the plan's `.build` paths were re-verified after the move to `~/Developer/JAASNOTES`):

```sh
xcodebuild -version
xcrun swift --version
plutil -lint JAASNotes.xcodeproj/project.pbxproj
xcodebuild -list -project JAASNotes.xcodeproj
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -configuration Debug -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Caches/JAASNotes/DerivedData" build
```

Tests:

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Caches/JAASNotes/DerivedData" -resultBundlePath "$HOME/Library/Caches/JAASNotes/TestResults/JAASNotes-01.xcresult" test
```

Verification of the built app:

```sh
vtool -show-build "$APP/Contents/MacOS/JAASNotes"
codesign -d --entitlements - "$APP"
```

### Results

- `plutil -lint`: OK
- Debug build: **BUILD SUCCEEDED**, no warnings from project code. The single warning is Xcode's benign `appintentsmetadataprocessor` notice that no AppIntents framework is linked.
- Tests: **TEST SUCCEEDED**
  - `AppConfigurationTests.testBundleIdentifierIsStable`: passed
  - `LaunchUITests.testLaunchShowsThreeColumnShell`: passed (app launched and the shell's labels were found)
- Minimum OS in the binary: `minos 14.0`. SDK 26.2.
- Entitlements in the signed bundle: `com.apple.security.app-sandbox` = true.
- Signing: ad-hoc (`Sign to Run Locally`), no team identifier. This is a local build, not a signed or notarized distribution artifact.

### Issues found and resolved

1. **Wrong group hierarchy in the hand-written project file.** Source files resolved to the project root. Fixed by referencing group objects instead of file references for folders.
2. **Code-signing failure: "resource fork, Finder information, or similar detritus not allowed".** The repository lives in `~/Desktop`, which iCloud Drive syncs. Finder and file-provider attributes end up on the built `.app`, and codesign rejects them. The default `.build/DerivedData` inside the repository reproduced the failure. Fixed by directing DerivedData and result bundles to `~/Library/Caches/JAASNotes/`.
3. **`.gitignore` hid the `Features/Library` source folder.** The pattern `Library/` matched any folder with that name. Anchored to `/Library/` so only a root-level folder is ignored. Verified with `git add -n`.

### Remaining risks

- **Verify the location stays out of iCloud.** The repository is outside Desktop/Documents now. If it is ever moved back into an iCloud-synced folder, the signing failure described above will return.
- The placeholder shell has no data, so nothing is persisted yet.
- The UI test depends on the system's accessibility permissions for the test runner. It passed here; a fresh machine may need the runner granted permission.

## 01-02 — Version-1 model, serial repository, first-launch initialization

- **Status:** pass (complete)
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Environment

- Same as 01-01: Apple M3 Pro, macOS 26.6.2, Xcode 26.3 (Swift 6.2.4), deployment target macOS 14.0, Swift 5 mode with complete concurrency checks.
- Stores are disk-backed SQLite files in unique temporary directories. No in-memory stores.

### Changes

- `JAASNotes/Persistence/JAASNotes.xcdatamodeld`: version-1 model (`JAASNotes.xcdatamodel`, identifier `1`). Entities:
  - `LibraryMetadata`: `libraryID` (unique), `createdAt`, `formatVersion` (Int32).
  - `Folder`: `id` (unique), `name`, `normalizedName` (unique), `createdAt`, `modifiedAt`, `isDefault`; to-many `notes` with Deny delete.
  - `Note`: `id` (unique), `title`, `bodyPlainText`, `createdAt`, `modifiedAt`, `deletedAt` (optional), `revision` (Int64), required `folder` with Deny delete.
- `JAASNotes/Persistence/CoreData/LibraryRecords.swift`: `NSManagedObject` subclasses named to match the model.
- `JAASNotes/Persistence/CoreData/CoreDataStack.swift`: opens the SQLite store with automatic migration disabled, and closes it cleanly.
- `JAASNotes/Persistence/CoreData/LibraryRepository.swift`: an `actor` that owns one private-queue context. Each mutation runs in one transaction and saves before returning; failures roll back. Callers receive value snapshots only.
- `JAASNotes/Persistence/Files/LibraryLocation.swift`: stable layout `<root>/Library/Store.sqlite`. The root is `Application Support/JAASNotes` by default and is injected in tests.
- `JAASNotes/Domain/FolderName.swift`: trimming, normalized key (case- and diacritic-insensitive, canonical composition), and reserved names `All Notes` and `Recently Deleted`.
- `JAASNotes/Domain/LibraryTypes.swift`: `LibraryMetadataSnapshot`, `FolderSnapshot`, `NoteSnapshot`, and typed `LibraryError`.
- Tests: `JAASNotesTests/Unit/FolderNameTests.swift`, `JAASNotesTests/Unit/LibraryLocationTests.swift`, `JAASNotesTests/Integration/LibraryRepositoryTests.swift`.

### Behavior implemented

- First initialization writes the metadata record and the default `Notes` folder in one save. A repeat call returns the same metadata and adds nothing.
- The initializer refuses inconsistent partial data (folders without metadata, several metadata records, or not exactly one default folder). It reports the problem and does not repair it.
- `createFolder` rejects empty, reserved, and duplicate names. Duplicate detection uses the normalized key.
- `createNote` requires an existing folder and starts notes at revision 1.
- `activeNotes` excludes trashed notes (`deletedAt != nil`).

Scope note: `createFolder` and `createNote` are implemented here because the uniqueness and folder-relationship invariants need real writes to test. Folder rename, moves, and the note UI remain in 01-03 and 01-05.

### Commands run

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-03.xcresult test
```

### Results

- Build: **BUILD SUCCEEDED**. Two Sendable warnings from the first build were fixed by marking the transaction-helper closures `@Sendable`. The final build reports no warnings from project code.
- Tests: **TEST SUCCEEDED**, 18 unit and integration tests plus the existing UI test.
  - `FolderNameTests` (6): trimming and display spelling, case and diacritic normalization, canonically equivalent spellings, distinct names, empty input, reserved names.
  - `LibraryLocationTests` (2): stable store path, default root name.
  - `LibraryRepositoryTests` (9): first-launch metadata and single default folder; no metadata before initialization; repeat initialization changes nothing; library, folders, and notes survive closing and reopening the SQLite store; duplicate folder names rejected ignoring case and diacritics; invalid folder names rejected without changing data; note requires an existing folder; new notes start at revision 1 with unique IDs; Unicode title and body stored losslessly (compared by scalars, so canonical equivalence cannot hide a change).

### Remaining risks and gaps

- The app does not open the library yet. `LibraryShellView` is unchanged, so 01-02 is proven by tests, not by the running UI. The first-launch flow in the app comes with 01-03.
- Store-open failures (corrupt or future-version stores) are mapped to `LibraryError.storeLoadFailed`, but no recovery UI exists until 01-08.
- Test cleanup uses `try?` in `defer` blocks, because `defer` cannot await. Application code does not do this.
- Migrations are not exercised: there is only version 1 and no older version to migrate from.

## 01-03 — Note creation and plain-text editing

- **Status:** NOT COMPLETE. Everything below passes automatically. One acceptance item still needs a human check: a real Japanese or Chinese input-method session in the running app (see Remaining gaps).
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Environment

- Same as 01-01 and 01-02: Apple M3 Pro, macOS 26.6.2, Xcode 26.3 (Swift 6.2.4), deployment target macOS 14.0.
- Accessibility and UI tests ran on this Mac; the test runner needs permission to control the app.

### Changes

- `Features/Library/LibraryModel.swift`: `@MainActor @Observable` app state. It opens the library, holds the folder and note snapshots, the sidebar and note selection, in-memory drafts (title and body keyed by note ID), and a title-focus request for a new note. New notes go to the selected folder, or to the default Notes folder when All Notes is selected.
- `Features/Editor/PlainTextEditor.swift`: `NSViewRepresentable` over `NSTextView` (plain text, native undo, spelling, and input methods). `PlainTextEditorDelegate` reports committed text only. It skips marked (in-composition) text and never replaces text while a composition is in progress.
- `Features/Editor/NoteEditorView.swift`: title `TextField` and body editor. Each note gets a fresh editor (`.id(note.id)`), so each note has its own undo history. A new note takes title focus.
- `Features/NoteList/NoteListView.swift`: rows show the draft title (or "Untitled Note"), a two-line preview, and the modified date. Empty state with a New Note action.
- `Features/Library/LibraryShellView.swift`: three columns. The sidebar lists All Notes and the folders from the store. Opening, failure, and operation-error states are shown.
- `App/JAASNotesApp.swift`: File > New Note with Cmd-N.
- `Domain/LibraryTypes.swift`: `LibraryError` now conforms to `LocalizedError`. Messages never include stored details or paths.
- Debug-only test hook: `JAASNOTES_TEST_LIBRARY_NAME` puts the library under the app's sandbox temporary folder. The hook is compiled out of release builds, so tests never touch Application Support.
- Sidebar: the placeholder "Recently Deleted" item was removed. It returns with 01-07 (soft deletion and Recently Deleted).

### Commands run

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-09-<n>.xcresult test
```

### Results

- Build: **BUILD SUCCEEDED**, no warnings from project code.
- Tests: **TEST SUCCEEDED** on two consecutive full runs.
  - Unit (25): the 6 folder-name, 2 location, 9 repository, and 1 bundle-ID tests from earlier substages, plus 5 new `LibraryModelTests` and 2 `PlainTextEditorDelegateTests`.
    - `LibraryModelTests` (new): opening creates the default folder; creating notes selects and focuses each new note; new notes go to the default folder under All Notes; drafts survive switching notes; a corrupt store file is reported as a failure and left byte-for-byte unchanged.
    - `PlainTextEditorDelegateTests` (new): committed typing reports the whole text, including Unicode and emoji; marked text is not reported until it is committed (`setMarkedText` then `insertText`).
  - UI (3): `LaunchUITests` (shell and empty states) and `NoteEditingUITests` (2):
    - `testCreateEditSwitchAndKeepDrafts`: creates two notes, types Unicode, including a decomposed sequence in the body and Japanese text, then switches back and checks both drafts.
    - `testNativeUndoRevertsBodyTyping`: Cmd-Z in the body removes the typed text. This is native `NSTextView` undo driven by real keystrokes.

### Acceptance check against the 01-03 criteria

| Criterion | Evidence | Status |
| --- | --- | --- |
| Multiple notes can be created and edited | Unit and UI tests | Pass |
| Unicode input works | UI test types emoji, accents, and Japanese; unit test checks the reported text | Pass |
| Native text undo works | UI test with Cmd-Z | Pass |
| IME (marked text) works | Delegate-level test only: marked text is not reported, and commit reports the final text | **Partial. No live input-method session has been run.** |
| Switching selection retains drafts | `LibraryModelTests` and `testCreateEditSwitchAndKeepDrafts` | Pass |

### Remaining gaps and risks

- **Live IME not tested.** The delegate test shows the marked-text protocol is handled, but no real Japanese or Chinese keyboard session has run. Needed: switch to a Japanese input source, type a composed phrase in the body and in the title, and confirm nothing is lost and the composed text commits once.
- **Drafts are in memory only.** Quitting the app loses edits made since the last save. Autosave and durable commits come in 01-04. Note creation itself is saved immediately.
- **The list does not reorder while typing yet**, because drafts don't change `modifiedAt`. Reordering after saves is 01-05's job.
- **Focus on a new note** depends on a one-turn delay (`await Task.yield()`). Without it, the title field of a second new note did not take focus in UI tests. The timing is SwiftUI-specific, so it may need revisiting after the 01-09 focus work.
- **UI test libraries** are created in the app's sandbox temporary folder. The test runner can't clean them up, so macOS removes them with its temporary-file cleanup.
- VoiceOver and keyboard-only passes are not done. They belong to 01-09.

## 01-04 — Autosave, flushing, failure handling, and recovery copies

- **Status:** pass (complete), with the caveats listed under Remaining gaps.
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Environment

- Same as earlier substages: Apple M3 Pro, macOS 26.6.2, Xcode 26.3 (Swift 6.2.4), deployment target macOS 14.0.

### Changes

- **Storage:** `LibraryRepository.updateNote` saves only when the stored revision still matches the expected one. A stale editor gets `revisionConflict` and never overwrites newer data. Identical text changes nothing: the revision and `modifiedAt` stay the same. Text is compared by Unicode scalars, so a save never hides an encoding change.
- **`NoteStore` protocol** (`Domain/NoteStore.swift`): the durable operations the model needs. `LibraryRepository` implements it, and tests and Debug builds wrap it.
- **Autosave** (`LibraryModel`):
  - Each edit bumps a per-note draft revision. A note is dirty while its draft revision differs from the last revision the store acknowledged.
  - Autosave waits 500 ms after the last edit. Continuous typing forces a save once unsaved text has waited 2 s.
  - Saves are serialized. A save that finishes after a newer edit leaves the newer text dirty. The next pass saves it.
  - A note counts as saved only after the store acknowledges that exact draft revision.
  - Unchanged text reported by a view (for example, on focus changes) is ignored and does not start a save.
- **Failures:** a failed save keeps the draft and the failure message. The message stays until a save succeeds, so repeated background flushes don't re-show the alert. Selection changes and new-note creation first flush pending text. If the flush fails, they are refused and the status line shows Retry, Save Recovery Copy, and Discard.
- **Recovery copy** (`Services/RecoveryCopy.swift`): JSON with the unsaved notes (IDs, folder, title, body, and stored revision). It is written atomically, read back, and compared before it is reported as saved.
- **Discard** asks for confirmation and returns each dirty note to its stored text.
- **Quit** (`App/AppDelegate.swift`): if text is unsaved, Quit waits for a flush. If the flush fails, Quit is cancelled and the window shows the failure. Save (Cmd-S) is in the File menu.
- **Save status line** in the editor: Saved, Unsaved changes, Saving…, or Not saved, with the failure actions.
- **Debug-only failure switch:** `JAASNOTES_TEST_FAIL_SAVES` wraps the store so every write fails. It is compiled out of release builds, like the library-name switch.

### Commands run

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-24-<n>.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 90 test
```

### Results

- Build: no warnings from project code.
- Tests: **TEST SUCCEEDED on two consecutive full runs.** 44 unit and integration tests and 7 UI tests.
  - Unit and integration additions: `AutosaveTests` (8: persists across reopen; failed save keeps draft; retry without duplicates; an old save finishing after a newer edit stays dirty; selection and new-note creation blocked while failing; recovery copy contains unsaved text and is verified; failed recovery copy reported; discard returns to stored text), `AutosaveScheduleTests` (2: debounce delay; 2-second maximum wait during continuous typing), `LibraryRepositoryTests` (4: identical text changes nothing; changed text increments revision and date; stale revision rejected; missing note reported), `RecoveryCopyTests` (4: round trip; scalar-exact text; foreign file rejected; unwritable location reported).
  - UI additions (`NoteEditingUITests`): edits survive Cmd-S then quit and relaunch; typing just before Cmd-Q is saved on relaunch; with every write failing, Cmd-Q is cancelled, the failure is shown, the app keeps running, and the draft stays; Discard asks first, then returns to the stored text.

### Acceptance check against the 01-04 criteria

| Criterion | Evidence | Status |
| --- | --- | --- |
| Latest edits survive normal restart | UI: Cmd-S + relaunch; Cmd-Q + relaunch | Pass |
| Delayed saves don't discard drafts or report Saved early | Unit: old save completing after a newer edit | Pass |
| Failed saves don't discard drafts or report Saved | Unit and UI | Pass |
| Failure can cancel Quit | UI: Cmd-Q cancelled with failing writes | Pass |
| Retry and recovery copy | Unit tests for both. The Retry button and the save panel were not clicked in automation. | Logic pass; UI click-through not automated |

### Decisions made during this substage

- **Quit failure shows in the window, not in a modal dialog** (D-010). A modal alert created during termination crashed the app (`NSAlert` raised inside `NSWindow` initialization).
- **Autosave and failure state** (D-011). Dirty state is revision-based. A failure message persists until a save succeeds.

### Bugs found and fixed during this substage

1. **Crash on Cmd-Q with a failed save.** `NSAlert` raised an exception during `applicationShouldTerminate`. Fixed by removing modal dialogs from termination. See D-010.
2. **Spurious dirty state from unchanged text.** The text field reported unchanged values, which made notes dirty and started saves. Fixed by ignoring identical text in `updateDraft`.
3. **Failure alert re-shown on every background flush.** Each retry cleared and reset the failure message, so the alert returned whenever the window lost focus. Fixed by keeping the message until a save succeeds.
4. **Test-store race.** `resumeUpdate()` cleared its paused flag only after the woken call ran, so a caller could see a stale state and release a save early. Fixed by clearing the state synchronously.
5. **`XCUIApplication.terminate()` skips the quit handler.** It is not a normal quit, so the quit-flush check uses Cmd-Q.

### Remaining gaps and risks

- **Window closed while a save is failing.** Quit is cancelled with no window to show the failure, so Cmd-Q looks like nothing happened until the window is reopened. The failure is kept and shown when the window is reopened. Needs a fix in 01-08's recovery UI.
- **Window close is best-effort.** Closing the window flushes but cannot block the close. A failed flush keeps the draft in memory.
- **A forced quit, a crash, or power loss can lose edits** since the last successful save. Edits typed in the last 0.5 s, or in the last 2 s during continuous typing, are the exposure window. This is the documented limit in the plan.
- **Failures were injected, not produced by a real disk fault.** Full-disk and permission failures are covered by the injection points and the injected store wrapper. A real full disk was not produced.
- **Retry button and the NSSavePanel** are not clicked by automation. Manual check: fail saves with `JAASNOTES_TEST_FAIL_SAVES=1`, press Retry, and save a recovery copy, then open the file.
- **Focus on a new note** is still best-effort (see 01-03). The UI test clicks the title before typing.
- Accessibility of the status line (VoiceOver announcements) is not checked; it belongs to 01-09.

- **Flaky UI test (observed once).** In the full run on 2026-10-15, `testFailedSaveCancelsQuitAndKeepsDraft` failed at the "Changes Not Saved" wait (5 s timeout). The same test passed when rerun alone, and the earlier full runs passed. The cause is not diagnosed. Next step: rerun the full UI suite several times and, if it recurs, lengthen that wait or check the status-line timing.
