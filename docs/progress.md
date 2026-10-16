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

## 01-05 — Folders, note moves, list ordering, and empty states

- **Status:** pass (complete).
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Changes

- **Repository:** `renameFolder` (the default Notes folder is fixed, duplicate names are rejected with the folder's own spelling excluded, and renaming to the same spelling changes nothing). `moveNote` (a move updates `modifiedAt` and the revision; moving into the current folder changes nothing; stale revisions and missing folders are rejected). Active notes are sorted newest first with the UUID string as tie-breaker (`NoteSnapshot.newestFirst`).
- **Model:** `createFolder` (selects the new folder) and `renameFolder` throw, so the sheet can show the message inline. `moveNote` saves pending text first and is refused if that save fails. Selection clears when the selected note leaves the shown folder. List order is re-applied only when focus leaves a note, so rows do not move while typing.
- **UI:** New Folder toolbar button and sheet (inline errors, Return and Escape); folder rename from the context menu (disabled for Notes); note count badges; Move To toolbar menu and row context menu (current folder disabled); empty-folder state.
- **Test wrappers:** `FaultyNoteStore` can fail folder and move writes (`failNextStructuralWrites`).

### Commands run

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-full-0105-<time>.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 90 test
```

### Results

- Build: succeeds.
- Full suite: **TEST SUCCEEDED**. 61 unit and integration tests and all UI tests, including the new `FolderUITests`.
- Added integration tests (`FolderAndMoveRepositoryTests`, 9): rename persists across reopen and keeps uniqueness; case-only rename of itself allowed; duplicate rejected and both folders unchanged; default folder fixed; empty and reserved names rejected; move persists across reopen and updates revision and `modifiedAt`; move into same folder is a no-op; stale revision and missing folder leave the note unchanged; newest-first order with stable tie-breaker.
- Added model tests (`FolderModelTests`, 8): created folder selected; failed creation creates nothing; rejected rename keeps the old name; move saves pending text first; move refused while saves fail and the draft survives; failed move write leaves note and selection unchanged; selection clears when the note leaves the folder; selecting a note re-applies order.
- UI (`FolderUITests`): create folder, rename it, create a note in it, move it with the toolbar menu, quit, relaunch. The folder name and the empty folder state survive relaunch.

### Acceptance check against the 01-05 criteria

| Criterion | Evidence | Status |
| --- | --- | --- |
| Operations survive restart | Integration reopen tests and `FolderUITests` relaunch | Pass |
| Invalid folder names leave data consistent | Repository and model tests for empty, reserved, and duplicate names | Pass |
| Failed moves leave data and selection consistent | Model tests with injected failures | Pass |

### Remaining gaps and risks

- The inline error text in the folder sheet is not checked by UI automation; only the model path is tested.
- Drag-and-drop moves are not implemented (optional, Stage 2).
- Folder names are not visually checked for long or right-to-left text yet (01-09).
- The sidebar "New Folder" button is placed in the split view's toolbar. A sidebar-attached toolbar item did not appear in automation.

## 01-06 — Literal search, scopes, draft overlay, and stale-result protection

- **Status:** pass (complete).
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Changes

- **Repository:** `searchActiveNotes(matching:)` uses `CONTAINS[cd]` with a bound value, so search is literal. Trashed notes are excluded.
- **Model:** search text is debounced by 200 ms. Each edit or save bumps a generation number, and a result for an older generation is dropped. Results are the stored matches plus any in-memory draft that matches, so a database match never hides unsaved text. "This Folder" scope filters in memory over one global query. Creating a note clears the search so the new note is visible.
- **UI:** `.searchable` in the note list with All Notes / This Folder scopes; `ContentUnavailableView.search` for no results. Search covers Recently Deleted only while that view is selected.

### Results

- Unit and integration: `SearchRepositoryTests` (2) and `SearchModelTests` (6), including the late-result case with a held query and literal patterns (`a.c`, `*`, `%`, `[a]`).
- UI: `SearchUITests` types a diacritic-free query and finds an accented title, then shows the no-results state.

### Acceptance check

| Criterion | Evidence | Status |
| --- | --- | --- |
| Unicode queries find title and body matches | `SearchRepositoryTests`, `SearchUITests` | Pass |
| Deleted notes are excluded from active scopes | `testTrashedNotesAreExcludedFromSearch`, `testSearchCoversRecentlyDeletedOnlyWhenSelected` | Pass |
| Rapid queries cannot show obsolete results | `testOlderSearchFinishingLateCannotReplaceNewerResults` | Pass |

### Remaining gaps

- Search reruns the query over all active notes on every save while a search is active. Performance is measured in 02-04's sorting checks, not here.
- Searching folder names and attachments is excluded by design (plan §7).

## 01-07 — Soft deletion, Recently Deleted, and restore

- **Status:** pass (complete).
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Changes

- **Repository:** `trashNote` sets `deletedAt` and bumps the revision; it does not change `modifiedAt`, content, or folder. `restoreNote` clears `deletedAt`, returns the note to its folder, and bumps the revision. `deletedNotes` lists trash most-recently-deleted first. Trash and restore reject a stale revision, an already-trashed note, or a note that is not trashed.
- **Model:** Recently Deleted is a sidebar item. Its notes are read-only and are kept out of `notes`, so no autosave path can write them. Trash moves selection to the neighboring note, flushes pending text first, and is refused if that save fails. Creating a note from Recently Deleted switches to All Notes.
- **UI:** Delete button and context-menu item; Recently Deleted rows show the deletion date; the editor's status line says "Deleted … Read-only." with Restore.
- **Not built, by design:** permanent deletion and Empty Recently Deleted are Stage 2 (02-03). Nothing purges automatically.

### Results

- Integration: `TrashRepositoryTests` (5) — content, folder, and `modifiedAt` survive trash, reopen, and restore; invalid transitions and stale revisions are rejected; trash order; trashed notes excluded from search.
- Model: `TrashModelTests` (7) — neighbor selection with pending text saved first; refusal while saves fail; failed restore keeps the note in trash; trashed notes cannot be edited; restore returns to the folder; creating from trash shows the new note; search covers trash only when selected.
- UI: `TrashUITests` deletes a note, quits, relaunches, finds it in Recently Deleted, restores it, and finds it in All Notes.

### Remaining gaps

- Cmd-Delete trash shortcut is in 01-09 with focus routing; the toolbar and context menu cover it here.

## 01-08 — Backups, restores, recovery, and store-open failure

- **Status:** pass (complete), with the caveats below.
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Changes

- **Services:** `LibraryBackupService` (quiesced snapshot, validation, SHA-256 manifest, publish by rename, listing, retention of 7 automatic backups, sanitized diagnostic report, move-aside helper, export). `LibraryRestoreService` (validated restore, transaction marker, startup recovery, rollback).
- **Model:** Back Up Now, automatic backup at most once a day after a change (checked when the app becomes active), Restore with a pre-restore backup first, Retry, Create New Library after moving the old one aside, Save Diagnostic Info, Copy Backup. Operations wait while the library is locked.
- **Store safety:** `CoreDataStack.checkCompatibility` refuses an existing file that is not a JAASNotes store, before any writable open (D-014).
- **UI:** `StoreRecoveryView` replaces the editor when the library cannot open (Retry, Restore From Backup, Save Diagnostic Info, Create New Library). `BackupsSheet` lists backups with last-backup date and failure messages, and offers Back Up Now, Copy, and Restore.

### Results

- Integration: `BackupRestoreTests` (12 tests): fresh-library restore; replacing a populated library with the old one kept in Recovery; identical note IDs after restore; damaged backup refused before any change (checksum); newer manifest refused without change; invalid packages not listed; interruption after moving the library aside is rolled back at startup; interruption after installing is completed at startup; corrupt store left byte-identical and not replaced; foreign SQLite file refused and left byte-identical; Create New Library keeps the old file; retention keeps 7 automatic and never prunes manual; once-a-day automatic rule; pre-restore backup taken before a restore; exported copy restores.
- Full suite: 96 unit and integration tests pass.

### Bugs found and fixed during this substage

1. Checksums were taken before validation. Opening the staged copy changed its `-shm`, so restore refused a good backup. Fixed: checksum after validation (D-012).
2. The repository and model used different clocks, so automatic backups ran on every activation. Fixed: the repository takes the model's clock.
3. A foreign SQLite file was given Core Data tables and then initialized as an empty library. Fixed: compatibility check before writable open (D-014).

### Remaining gaps and risks

- **Newer-model fixture not built.** An attempt to build a store with an added entity crashed inside Core Data in the test. The refusal path is covered by the foreign-file fixture and the same metadata check. A real newer-model store is still needed before 02-01, when migrations exist.
- **Store-open recovery UI is not click-tested.** The model paths are tested; the buttons are not driven by UI automation.
- **Recovery/ is never pruned.** Retention for moved-aside libraries needs an owner decision.
- **Interruption at each snapshot boundary is not injected.** Only the restore swap has interruption points. Snapshot copying is covered by the staging-and-rename design, not by injected faults.
- **Disk-full and permission failures are not produced for real.** They are not injected in the backup path either.

## 01-09 — Menus, focus routing, shortcuts, light and dark, accessibility

- **Status:** COMPLETE, on the owner's report of a manual VoiceOver and keyboard-only pass. Automated shortcut tests (`KeyboardUITests`) also pass. The owner has not yet listed which checks were covered, or the macOS version used; this entry is to be updated when that is known.
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Changes

- **Menus:** File: New Note (Cmd-N), New Folder (Shift-Cmd-N), Rename Folder…, Move Note To ▸, Move to Recently Deleted (Cmd-Delete), Restore Note, Backups…. Edit: Find in Note… (Cmd-F, native find bar in the body), Search Notes (Shift-Cmd-F). View: All Notes (Cmd-1), Recently Deleted (Cmd-2). Save (Cmd-S).
- **Cmd-Delete routing:** when the first responder is a text view (body or title field editor), the command sends `deleteToBeginningOfLine` to the responder; only the note list trashes the selected note.
- **Focus:** Shift-Cmd-F focuses the search field. `searchFocused` is macOS 15 API; on macOS 14 an AppKit fallback finds the `NSSearchField`. The fallback is not exercised on this Mac.
- **Window reopen:** unchanged; SwiftUI's WindowGroup reopens from the Dock.

### Results

- UI (`KeyboardUITests`, 4 tests, all pass): Shift-Cmd-N opens the folder sheet; Cmd-Delete in the body edits text and keeps the note; Cmd-Delete in the note list moves the selected note; Shift-Cmd-F puts the caret in the search field.

### Remaining gaps (must be closed before 01-09 is complete)

- **VoiceOver walkthrough not run.** Required by the plan. Labels exist for the toolbar buttons, rows, status lines, and search results, but a screen reader pass has not happened.
- **Keyboard-only walkthrough not complete.** Tab order across sidebar, list, title, and body is not verified.
- **Light and dark appearance not checked** with screenshots or UI tests.
- **Long text, large Dynamic Type, and right-to-left input** not checked.
- **Settings window (Cmd-comma)** is not implemented. It is not needed for Stage 1's listed controls, but the plan lists it under menus.
- **Window close and reopen** are not checked after closing the only window.

## 01-10 — Stage 1 matrix status (partial)

- **Status:** NOT COMPLETE.
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Added

- `ForceQuitUITests.testSavedNoteSurvivesForceTermination`: a saved note survives SIGKILL (`NSRunningApplication.forceTerminate`). Passes.
- `docs/storage.md` (layout, snapshot and restore procedures) and `docs/testing.md` (commands, injection points, matrix status).

### Still open

- Matrix items 2, 5, 7, 8, and 9 have gaps listed in `docs/testing.md`. Item 9 (VoiceOver, keyboard-only, appearance, IME, long text) needs a manual run on the owner's Mac.
- Force kill during a pending save is not tested; the uncommitted window (up to 2 seconds of typing) is documented in the README instead.
- CI in `.github/workflows/ci.yml` has never run.
- Stage 1 exit gate not met, so Stage 2 has not started.

- **Update:** matrix item 8's other-model case is now covered by `BackupRestoreTests.testStoreWrittenByAnotherModelVersionIsRefused`, which rewrites a real store's Core Data model hashes. It passes, and the file is unchanged after the refusal.

### 01-09 owner report

- The owner reports the VoiceOver and keyboard-only walkthrough passed ("everything works perfectly"). Coverage details, macOS version, and any unchecked items were not recorded. Update this section with them.

## 01-10 — Stage 1 closure

- **Status:** COMPLETE for the recorded environment (macOS 26.6.2, Apple M3 Pro, Xcode 26.3). Open environment gaps are listed below and are not claimed as verified.
- **Date:** 2026-10-15
- **Commit:** not committed yet

### Evidence added

- `PendingSaveKillUITests`: killed with unsaved text; the library opens and the saved note remains. Passes.
- `BackupRestoreTests.testSnapshotInterruptedAtPublishLeavesNoBackupAndKeepsTheLibrary`: a failed final rename leaves no listed backup, no staging debris, and an intact library. Passes.
- `ForceQuitUITests`: kill after a confirmed save. Passes.
- Owner's manual pass on macOS 26.6.2: VoiceOver walkthrough and keyboard-only pass recorded as passed.

### Environment gaps (not verified)

- **macOS 14 runtime:** not run. No macOS 14 machine or VM is available. The deployment target is 14.0, so this is a compile-time setting only.
- **CI:** `.github/workflows/ci.yml` passes on `21b2225` (GitHub Actions, macOS 15 runner, Xcode 26.3): build, unit and integration tests, and UI tests. The previous run failed in `FolderUITests` at the toolbar Move To menu, which the runner could not open; that step now uses the row context menu.
- **Intel:** not tested.

## 02-01 to 02-03 — Version 2, pinning and sorting, folder removal and permanent deletion

- **Status:** 02-01 to 02-04 COMPLETE. 02-04 keyboard and VoiceOver check reported passed by the owner on macOS 26.6.2 (M3 Pro).
- **Date:** 2026-10-15
- **Commit:** not committed yet

### 02-01 — Version-2 model and migration

- `JAASNotes 2.xcdatamodel` adds `Note.isPinned` (D-016). The version-1 model is unchanged.
- `LibraryMigrationService`: pre-upgrade backup, upgrade of a copy with `NSMigrationManager`, a row-for-row comparison of the original and the copy, then the restore swap (D-017). Interruption before install leaves the original and the staging is removed. Unknown files are refused and left unchanged.
- The embedded fixture `V1LibraryFixture` is a real version-1 store (two folders, three notes, one trashed, Unicode text). It was written by the version-1 model before version 2 existed.
- Restores migrate a staged version-1 backup before validating it.
- Tests (`MigrationTests`, 4): the fixture opens upgraded with IDs, text, revisions, folders, and Recently Deleted unchanged; an interrupted upgrade leaves the original, and a retry succeeds; an unknown file is refused unchanged; a current library is not upgraded or backed up.

### 02-02 — Pinning and sorting

- `setNotePinned` changes the pin and revision, not `modifiedAt` (D-018). Stale revisions are rejected.
- Ordering: pinned first, then Date Modified, Date Created, or Title, then UUID string. Title sorting uses `localizedStandardCompare`, so accented and case variants sort naturally.
- The sort choice is stored in `UserDefaults`. Re-sorting does not change drafts or the selection.
- UI: Pin/Unpin in the row menu, Shift-Cmd-P, a pin icon on pinned rows, a Sort menu in the list toolbar, and a Sort Notes By menu.
- Tests (`OrganizationTests`): pin persists and changes only the revision; stale pins are rejected; pinned-first ordering; each sort order; stable tie-breaking; sort and pin survive relaunch; re-sorting keeps unsaved text and the selection; a pin is refused while saves fail.

### 02-03 — Folder removal and permanent deletion

- `deleteFolder` moves active and trashed notes to Notes in the same transaction, then removes the folder. Moved notes get a new revision, and active notes get a new `modifiedAt`. The default folder cannot be removed.
- `permanentlyDeleteNote` removes only a trashed note with a matching revision. `permanentlyDeleteNotes` and `emptyRecentlyDeleted` take a `preDeletion` backup first, and cancel if it fails (D-019).
- UI: "Delete Folder…" in the folder menu with a confirmation; "Delete Permanently" and "Empty Recently Deleted" in the trash toolbar, each with a confirmation.
- Tests (`OrganizationTests`): folder removal keeps active and trashed notes, and they survive reopen; the default folder cannot be removed; permanent deletion needs a trashed note; deleting one note leaves the others; a backup is taken first; deletion is cancelled when the backup fails, and works once it succeeds; Empty Recently Deleted removes only trashed notes; removing the selected folder returns to All Notes.

### 02-04 — Polish and regression (partial)

- Settings window (Cmd-comma): sort order, last backup, Back Up Now, Manage Backups, and privacy text.
- Performance on 10,000 synthetic notes (`LargeLibraryPerformanceTests`, one run, this Mac): library load 0.06 s; re-sort 0.006 s; search 0.24 s including the 200 ms debounce. All are inside the provisional limits in the plan.
- Full suite passes: all unit, integration, and UI tests, including the migration, organization, and Stage 1 tests.
- **Owner check:** keyboard and VoiceOver passes on the new Stage 2 controls (Sort menu, pin shortcut, Settings window, folder and permanent-deletion dialogs) reported passed. No automated UI test covers them yet.
- **Not yet recorded:** Settings window appearance in light and dark mode.

## 03-01 — Version 3: RTF and checklist serialization, plain-text derivation, validation

- **Status:** COMPLETE for the isolated serialization, validation, migration, and repository rules. No UI uses rich text yet (03-02).
- **Date:** 2026-10-16
- **Commit:** not committed yet

### Changes

- **Model:** `JAASNotes 3.xcdatamodel` (current) adds `Note.contentFormatVersion`, `richTextData`, `checklistData`. Version 1 and 2 models are unchanged.
- **Domain:** `RichNoteContent`, `ChecklistSidecar` / `ChecklistItem` (versioned, stable UUIDs, UTF-16 paragraph ranges), `NoteBody` (`plain`, `rich`, `unreadable`), and `RichContentError` (messages never include note text).
- **Codec:** `RichTextCodec`: RTF in and out, 16 MiB cap, inline attachments refused on input and on read, plain text derived from the decoded RTF, line breaks normalized, checklist validation. Checklist ranges are remapped to the stored (NFC) text.
- **Repository:** `body(of:)`, `updateRichNote(id:expectedRevision:title:content:)`, `makeRecoveryCopy(of:)`. `updateNote` refuses rich notes. `currentFormatVersion` is 3.
- **Migration:** accepts version 2 as well as version 1 (D-023). Version 2 libraries upgrade without changing IDs, text, pins, or Recently Deleted.
- **Project:** `RichNoteContent.swift`, `RichTextCodec.swift` added to the app target; three test files added to the test targets.

### Commands

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new>.xcresult -only-testing:JAASNotesTests test
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new>.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 90 test
```

### Environment

- Xcode 26.3 (Swift 5 language mode), macOS 26.6.2, Apple M3 Pro (the Stage 1 and 2 environment). macOS 14 runtime not tested.

### Results

- Unit + integration: 145 tests pass (118 before this substage, plus 27 new).
- Full suite including UI tests: 145 unit/integration and 16 UI tests pass.
- New unit tests (`RichTextCodecTests`): Unicode round trip in NFC (emoji, ZWJ sequences, CJK, Arabic, Hebrew, RTF control words, braces, tabs); bold, italic, and underline survive; mixed line breaks normalize; non-RTF and empty data refused; oversized data refused before parsing; inline attachments refused on input; stored text must match the RTF; checklist ranges that are not whole paragraphs, overlap, are out of order, duplicate IDs, or cross a line break are refused; empty paragraphs can be items; checklist versions from the future are refused; damaged checklist JSON refused; checklist identity and state round trip; NFD input is stored precomposed with checklist ranges remapped.
- New integration tests (`RichNoteRepositoryTests`): a plain note becomes rich on first save and survives reopen with checklist identity; an identical save is not a revision; a stale save is refused and changes nothing; a plain save cannot discard formatting; search matches visible text, not RTF control words; damaged RTF, damaged checklist JSON, and a future format are reported with the saved text as fallback and their bytes stay identical after refused saves; a recovery copy keeps the text, lives in the same folder, and leaves the original alone; a recovery copy is refused for a note that opens normally.
- Migration (`MigrationTests`): a generated version-2 library (pinned and trashed notes, Unicode text) upgrades to version 3 with pins, revisions, and text unchanged, and no note converted to rich text.
- Backup (`BackupRestoreTests`): a rich note with checklist survives snapshot and restore into a fresh library.

### Bugs found during this substage

1. A checklist range could span a line break and still validate. Fixed: a range containing a line feed is refused.
2. RTF round trip changed `e` + combining acute to precomposed `é`. The string `==` comparison hid it. Fixed: NFC storage and paragraph remapping (D-021); tests compare scalars.
3. Inline attachments were dropped by the RTF writer without an error. Fixed: refused on input (D-020).

### Remaining gaps and risks

- The version-2 fixture is built in the test. A library written by the owner's Stage 2 build has not been opened by this version.
- Rich editing, formatting commands, and checklist controls do not exist yet. Stage 3 exit gate is not met.
- The migration's row comparison does not compare rich fields. For version 2 sources these are always empty, so the check is complete for upgrades from prior versions, but a future rich-to-rich migration will need it extended.
- A stale context can serve old values if another process writes the store. JAASNotes is the only writer, so this is documented, not handled.

## 03-02 — Basic rich text: formatting commands, Format menu, undo, saves

- **Status:** COMPLETE for the recorded automated evidence. Manual VoiceOver and keyboard checks of the new controls are not yet done (see remaining gaps).
- **Date:** 2026-10-16
- **Commit:** not committed yet

### Changes

- **Editor:** `PlainTextEditor` is now `NoteBodyEditor` (`Features/Editor/NoteBodyEditor.swift`). `NoteTextView` provides `toggleBold`, `toggleItalic`, `toggleUnderline`, `applyHeading1…3`, `applyBodyText`, and `toggleBulletList`. The first command on a plain note calls `onRichTextRequested`.
- **Synchronization:** `NoteBodyEditor.synchronize` replaces text only when the model's body differs, so selection and undo survive saves.
- **Model:** `Draft` gains `rich` (a formatted body with its checklist). `updateDraft(rich:)`, `prepareBody(for:)`, `bodyState(for:)` (loading, ready, unreadable), `makeRecoveryCopy(for:)`. Flushes use `updateRichNote` for formatted drafts and `updateNote` for plain drafts. Edits to a note that is not ready are ignored.
- **Editor UI:** a loading indicator while a formatted body loads. Unreadable formatting shows a banner with Make Recovery Copy, and the saved text is read-only.
- **Menu:** Format menu with Bold (Cmd-B), Italic (Cmd-I), Underline (Cmd-U), Heading 1–3 (Option-Cmd-1…3), Body Text (Option-Cmd-0), and Bulleted List (Shift-Cmd-L).
- **Protocol:** `NoteStore` gains `body(of:)`, `updateRichNote`, `makeRecoveryCopy`. The debug failure wrapper and the test fault-injection store forward them.
- **Renames:** `PlainTextEditor.swift` → `NoteBodyEditor.swift`, `PlainTextEditorDelegateTests.swift` → `NoteBodyEditorDelegateTests.swift`.

### Commands

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new>.xcresult -only-testing:JAASNotesTests test
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new>.xcresult -only-testing:JAASNotesUITests/FormatUITests test
```

### Results

- Unit + integration: 162 tests pass.
- `RichFormattingTests` (14): bold, italic, and underline apply only to the selection; toggling removes them; with no selection they change the typing style; undo reverts bold; headings set size and weight and leave the next paragraph alone; body text resets a heading; bullets toggle on one paragraph; the first command on a plain note asks the model once; typing in a plain note keeps it plain; read-only notes ignore commands; heading and bullet formatting survive the RTF round trip; an ordinary save leaves selection and undo intact; a changed body replaces the text.
- `RichEditingModelTests` (3): a formatted edit saves, reopens, loads as formatted, and keeps bold; a failed formatted save keeps the formatting in memory, reports Not saved, and then saves on retry; damaged formatting is read-only, takes no edits, and makes a recovery copy that keeps the saved text and leaves the original bytes unchanged.
- UI: `FormatUITests` confirms the Format menu offers every command.
- Full suite with the earlier UI tests: 16 UI tests run, one failure in the relaunch test (see below).

### Flaky UI test: `TrashUITests.testDeletedNoteSurvivesRelaunchAndCanBeRestored`

- With the 03-02 code the test failed in all three runs I made: once in the full suite, and in two solo runs. The failures were at different steps: the first click on New Note, and the check after relaunch.
- On the committed Stage 2 code (a temporary worktree, since removed) the same test failed once in two solo runs, with a different error ("Unable to find hit point for ScrollView").
- The screenshots from the failing runs include an accessibility hierarchy of a JetBrains IDE window. That suggests another app's window was on screen and overlapped the JAASNotes window during the test. This is not verified. Re-running with other apps closed would settle it.
- The test is not claimed as fixed, and it is not changed here.

### Remaining gaps and risks

- No manual VoiceOver or keyboard-only check of the Format menu, the formatting commands, or the unreadable banner.
- Return inside a bulleted list is not tested. AppKit's list continuation is assumed, not verified.
- The first rich save of a note changes its combining sequences to precomposed form (D-021).
- Rich bodies are encoded on the main actor for each save. This is fine for note-sized text, but unmeasured for very large notes.
- Recovery copies from "Save Recovery Copy" write plain text. Formatting is not kept in that file.
- Checklists have no editing controls yet. A checklist whose ranges no longer match the text will make its save fail with a clear message. This cannot happen from the 03-02 editor because no UI creates checklists yet, but 03-03 must keep the ranges in step with edits.

## 03-03 — Checklist controls, item identity through edits, paste, and undo

- **Status:** COMPLETE for the automated evidence below. A manual VoiceOver walkthrough of the checkboxes is not yet done (see remaining gaps).
- **Date:** 2026-10-16
- **Commit:** not committed yet

### Changes

- **Rules:** `Domain/ChecklistEditing.swift` (pure): `apply` (identity through edits, D-025), `toggled`, `addingItems`, `removingItems`, `item(at:)`, paragraph helpers. The codec's remap now uses the shared paragraph splitter.
- **Editor:** `NoteTextView` tracks each change with `shouldChangeText`/`didChangeText`, applies the rule, and registers the checklist for undo. It places one `NSButton` per item, sets the checklist indent, and reports text and checklist to the model. Checkbox clicks, Format commands, and undo use the same path.
- **Accessibility:** checkboxes are accessibility children of the text view, labelled "Checklist item, <first 60 characters>", identified as `checklistItem`, with checked state as their value.
- **Model:** `updateRichDraft(for:text:checklist:)` saves text and checklist together. `updateDraft` is plain text only.
- **Menu:** Format > Checklist (Shift-Cmd-C), Check or Uncheck Item (Shift-Cmd-Return).

### Commands

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new>.xcresult -only-testing:JAASNotesTests test
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new>.xcresult -only-testing:JAASNotesUITests/FormatUITests test
```

### Results

- Unit + integration: 188 tests pass.
- `ChecklistEditingTests` (17): typing inside an item keeps its identity and state, including emoji; Return at the end, in the middle, and at the start of an item; joining a plain paragraph into an item; joining an item with a plain paragraph before it; deleting a whole item; pasting lines inside an item; edits away from items; no checklist; toggling; adding and removing items per paragraph; selections that end at a paragraph start; item lookup.
- `ChecklistEditorTests` (8): typing, Return, paste (through `insertText`, not the clipboard), undo restoring text and checklist together, a checkbox click that reports and undoes, the Checklist command adding and removing items, the Check shortcut, and a plain note becoming formatted on its first checklist command.
- `RichEditingModelTests.testChecklistIdentityAndStateSurviveRestart`: three items with Japanese and emoji text keep IDs, checked state, and positions across a save and a restart.
- UI: `FormatUITests.testChecklistIsAddedAndCheckedFromTheKeyboard` adds a checklist with Shift-Cmd-C and checks it with Shift-Cmd-Return. The checkbox's accessible value changes from 0 to 1.
- Visual check: `FormatUITests.testChecklistLayoutScreenshot` attaches a screenshot. The attachment shows each checkbox on its own line, the checked state, and a wrapped line inside the indent. The note row preview reads the checklist text.

### Bugs found during this substage

1. A checklist range could span a line break. Fixed: the validator refuses it (03-01 follow-up).
2. Checkbox state in the UI test was checked as text. Accessibility values are numbers. The test compares numerically.
3. The first accessibility query did not see the checkboxes: subviews of a text view are not its accessibility children. Fixed: they are listed explicitly.

### Remaining gaps and risks

- No manual VoiceOver walkthrough of the checkboxes. The labels and values are tested automatically; what VoiceOver reads aloud has not been heard.
- Paste is tested through `insertText`. A real clipboard paste of rich content (for example from a web page) has not been tested.
- A paragraph with both a bullet and a checklist item is not supported.
- Text with carriage returns or U+2028/U+2029 line separators is not handled by the paragraph model. The save path normalizes them to line feeds, and that can move checklist positions. Native NSTextView input normally produces line feeds only.
- Checkbox layout is measured from one Mac and one font size.
- UI test runs in this environment were intermittently slow to find windows at launch. Several UI tests failed at launch on some runs and passed on rerun (see the 03-02 entry).

## 03-04 — Stage 3 gate (partial)

- **Status:** NOT COMPLETE. The automated gate passes. The accessibility part of the gate has not been run.
- **Date:** 2026-10-16
- **Commit:** not committed yet

### Automated gate: passing

- Full suite, final run: 207 tests pass (188 unit and integration, 19 UI). Nothing failed.
- Migration: version 1 and version 2 libraries upgrade with IDs, text, pins, and Recently Deleted unchanged (`MigrationTests`).
- Search: visible text in formatted notes is found, and RTF control words are not (`RichNoteRepositoryTests`). Previews show the same text (checked in the 03-03 screenshot).
- Failure paths: a failed formatted save keeps the formatting and can retry; damaged or newer formatting is read-only and never overwritten; a recovery copy keeps the saved text (`RichEditingModelTests`, `RichNoteRepositoryTests`).
- Stage 1 and 2 workflows: the existing UI tests (folders, editing, trash, search, keyboard, force-quit persistence) pass in the final run.

### Not run

- **Manual VoiceOver walkthrough** of the Format menu, the formatting commands, the checkboxes, and the unreadable-note banner. The labels, values, and identifiers are tested automatically. What VoiceOver announces, and the reading order, have not been checked.
- **Manual keyboard-only walkthrough** of the Format commands and the checklist shortcuts, including Tab order around the editor.
- **Light and dark appearance** of the checkboxes and the banner.
- **macOS 14** runtime. This Mac runs macOS 26.6.2.
- **Intel**: not tested.

### What the owner needs to do

1. Run the Format menu and the checklist shortcuts with VoiceOver on, and record what is announced and whether the checkboxes can be reached and toggled.
2. Confirm the shortcuts (Shift-Cmd-C for Checklist, Shift-Cmd-Return for Check or Uncheck Item, Option-Cmd-1…3 for headings) are the ones you want.
3. Record the result here. If anything fails, a new substage (03-05 or later) is needed; the gate is not marked complete until then.

### Environment note

- Some UI tests failed at launch on early runs and passed on rerun (see the 03-02 entry). The final full run passed. The cause is probably other windows on screen during the run, but that is not verified.
