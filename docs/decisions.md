# JAASNotes decisions

Architecture choices and approved changes. Entries are added as decisions are made; earlier entries are not rewritten.

## D-001 — Git repository inside JAASNOTES

- **Date:** 2026-10-15
- **Decision:** `JAASNOTES/` is its own git repository on branch `main`. Initialized by the owner's request.
- **Why:** The plan needs a fresh checkout that builds, and the parent folder contains unrelated files.
- **Open follow-up:** see D-003.

## D-002 — Bundle identifier and signing for local development

- **Date:** 2026-10-15
- **Decision:** Bundle ID `org.jaasnotes.JAASNotes` (owner confirmed). Local builds use ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM` empty). No team identifier is committed.
- **Why:** Local builds must not require a paid developer membership. The bundle ID determines the library location, so it is fixed now.

## D-003 — Project moved out of iCloud Desktop

- **Date:** 2026-10-15
- **Decision:** The repository lives at `~/Developer/JAASNOTES`, which iCloud Drive does not sync. Owner approved the move.
- **Why:** iCloud sync added metadata to built products, which codesign rejects, and could interfere with `.git`.
- **Consequence:** The plan's standard build commands work unchanged with `.build/DerivedData`. Build output is still gitignored.

## D-004 — Project file written by hand, Swift 5 mode, complete concurrency checks

- **Date:** 2026-10-15
- **Decision:** `project.pbxproj` was written directly, with no XcodeGen or other generator. Swift language mode 5 with `SWIFT_STRICT_CONCURRENCY = complete`, as the plan specifies.
- **Why:** The plan prohibits XcodeGen as a build requirement and recommends Swift 5 mode. The file has been validated with `plutil` and `xcodebuild -list`; the targets build and test.
- **Consequence:** Future target or file changes made in Xcode will rewrite the project file in Xcode's format. Keep the file as Xcode writes it.

## D-005 — Deployment target 14.0 built with Xcode 26.3 (SDK 26.2)

- **Date:** 2026-10-15
- **Decision:** `MACOSX_DEPLOYMENT_TARGET = 14.0` with Xcode 26.3. The binary reports `minos 14.0`.
- **Not verified:** runtime on macOS 14 Sonoma. The only tested OS is macOS 26.6.2 on this M3 Pro Mac. The plan requires recording this gap.

## D-006 — Core Data model and managed-object conventions (version 1)

- **Date:** 2026-10-15
- **Decision:** The model is a `.xcdatamodeld` with `codeGenerationType="none"`. Managed-object classes are hand-written in `LibraryRecords.swift` and named to match the entities (`FolderRecord`, `NoteRecord`, `LibraryMetadataRecord`), with `@objc` names that match the model.
- **Why:** Explicit mapping keeps managed objects inside the persistence layer and passes only snapshots out. It also makes the model's names the single source of truth.
- **Consequence:** Changing an entity means editing the model and the matching class by hand. Released model versions are never edited in place (per the plan's migration policy). Version 2 will add a new `.xcdatamodel` version.

## D-007 — Repository is an actor owning a private-queue context; automatic migration is off

- **Date:** 2026-10-15
- **Decision:** `LibraryRepository` is an `actor`. Each mutation is one `perform` block on a private-queue context, followed by a single save. `NSPersistentStoreDescription.shouldMigrateStoreAutomatically` and `shouldInferMappingModelAutomatically` are both `false`.
- **Why:** Matches the plan's single-writer rule and explicit transaction boundaries. Disabling automatic migration follows the plan's rule against blind migration of the only live copy.
- **Consequence:** A store created by a different model version will fail to open until a tested migration exists. That is the intended behavior and is covered by the 01-08 and 02-01 work.

## D-008 — Debug-only test library name; UI tests use the app's sandbox temporary folder

- **Date:** 2026-10-15
- **Decision:** In Debug builds only, `JAASNOTES_TEST_LIBRARY_NAME` places the library under the app's sandbox temporary folder (`JAASNotesTest-<name>`). The hook is compiled out of release builds. The UI tests pass a unique name per test.
- **Why:** The first attempt passed an absolute path from the test runner's temporary folder. The sandboxed app could not write there, so the app never opened the library. The name-based hook also keeps tests away from Application Support, which the plan requires.
- **Consequence:** UI test libraries are not removed by the tests. macOS clears the app's temporary folder.

## D-009 — Note editing: one NSTextView per note; drafts are in memory until autosave

- **Date:** 2026-10-15
- **Decision:** Each note's editor is recreated when the selected note changes (`.id(note.id)`). Unsaved title and body live in `LibraryModel.drafts` until 01-04 introduces autosave.
- **Why:** A fresh editor gives each note its own undo history and avoids resetting `NSTextView.string` during SwiftUI updates. Keeping drafts in memory until 01-04 keeps the save path in one place.
- **Consequence:** Quitting before 01-04 loses unsaved edits. Recreating the editor resets scroll position when switching notes; that is acceptable for this stage.

## D-010 — Quit with a failed save cancels Quit and shows the failure in the window

- **Date:** 2026-10-15
- **Decision:** `applicationShouldTerminate` flushes pending text. If the flush fails, Quit is cancelled. The shell's failure alert and the editor's status line offer Retry, Save Recovery Copy, and Discard. No modal dialog is shown during termination.
- **Why:** An `NSAlert` created inside `applicationShouldTerminate` crashed the app (`NSWindow` initialization raised an exception). The same dialog works in a normal context, so the problem is specific to termination. Showing the choices in the window avoids the crash and makes Cancel Quit the default outcome.
- **Consequence:** If no window is open when a save fails, Quit is cancelled and nothing else appears until the window is reopened. Addressed in 01-08's recovery UI.

## D-011 — Autosave is driven by per-note draft revisions; failures persist until a save succeeds

- **Date:** 2026-10-15
- **Decision:**
  - A note is dirty while its draft revision differs from the last store-acknowledged revision.
  - Autosave waits 500 ms after the last edit and forces a save after 2 s of continuous unsaved text.
  - Saves are serialized, and each save reports success only after the store acknowledges that exact draft revision.
  - A failure message stays until a save succeeds.
  - Unchanged text is ignored.
- **Why:** This matches the plan's rule that an older save can never mark newer text as saved. Keeping the failure message avoids repeated alerts from background flushes.
- **Consequence:** Retries do not reset the failure state. Only a successful save or an explicit discard clears it.


## D-012 — Backups are quiesced snapshots of a closed store, validated before publication

- **Decision:** a snapshot closes the live store, copies `Store.sqlite` (and any `-wal`/`-shm`), validates the copy with migration disabled, computes SHA-256 checksums after validation, writes `manifest.json`, and only then renames the package into `Backups/`.
- **Why:** copying an open WAL set with file operations is not consistent (plan §6). Checksumming before validation was wrong: opening a store updates its `-shm`, which the first test run caught.
- **Consequence:** the library is unavailable for the copy (milliseconds for Stage 1 sizes). Operations wait for the lock; pending text is flushed first.

## D-013 — Restores use a transaction marker and never delete the previous library

- **Decision:** a restore validates a staged copy, writes `Staging/restore-transaction.json`, moves the current library to `Recovery/`, installs the candidate, and validates it. Only then is the marker removed. `recoverInterruptedRestore` runs at every load and finishes or undoes an interrupted restore.
- **Why:** a crash between two directory renames must not leave the library missing (plan §6). Previous libraries are kept, not deleted, so a bad restore is recoverable by hand.
- **Consequence:** `Recovery/` grows with each restore or "create new library". Stage 1 does not prune it; the owner should decide retention before Stage 2.

## D-014 — A store is refused before any writable open unless it is a JAASNotes store

- **Decision:** `CoreDataStack.openContainer` checks an existing file with a read-only SQLite query for Core Data's `Z_METADATA` table, then reads the metadata and requires `NSStoreModelVersionHashesKey` and a compatible model. Refused files are never changed.
- **Why:** a foreign SQLite file received Core Data tables and was then initialized as an empty library, which the plan forbids. Reading metadata through Core Data wrote to the file too, so the read-only check runs first.
- **Consequence:** a store written by a different model version is refused rather than migrated. Migration is Stage 2's job (02-01).

## D-015 — Automatic backups are compared against the newest modification in the library

- **Decision:** an automatic backup runs at most once every 24 hours, and only when a note or folder was modified or trashed after the newest automatic backup. Repository and model share one clock, so the comparison is valid.
- **Why:** the plan requires "at most one per day after a change". Comparing dates needs no extra persisted state.
- **Consequence:** backups made by the app are not tracked by a separate change flag.

## D-016 — Version 2 adds `isPinned`; the version-1 model stays untouched

- **Decision:** `JAASNotes 2.xcdatamodel` is a new model version with `Note.isPinned` (default false). `JAASNotes.xcdatamodel` is not edited. The current version is set in `.xccurrentversion`.
- **Also changed in v2:** `Note.folder` uses the Nullify delete rule. The v1 Deny rule blocked deleting any note, because Core Data applies a relationship's delete rule to the object being deleted. The folder's own `notes` relationship still denies deleting a folder that has notes, so folder removal first moves its notes to Notes.
- **Consequence:** version 2 has not been released, so correcting its rules is allowed. A released version would need a new model version instead.

## D-017 — Upgrades are copied, compared, and installed through the restore swap

- **Decision:** before an upgrade the original is backed up as `preMigration`. The upgrade runs on a copy of the store with `NSMigrationManager`. The upgraded copy's notes and folders must match the original exactly, checked by a read-only comparison of both stores. Only then is the copy installed through the same transaction-marker swap that restores use.
- **Why:** the plan forbids in-place migration of the only copy and requires recoverable failure. Reusing the swap means one recovery path covers restores and upgrades.
- **Consequence:** an upgrade needs free disk space for the backup and the copy. Downgrades are not supported.

## D-018 — Pinning bumps the revision, not `modifiedAt`

- **Decision:** pinning and unpinning change the pin flag and revision. They do not change `modifiedAt`, because they are not content edits.
- **Why:** the autosave conflict check relies on the revision. Keeping `modifiedAt` stable means pinning does not reorder a note's "modified" position.

## D-019 — Permanent deletion needs a successful backup and a confirmation

- **Decision:** permanent deletion and Empty Recently Deleted take a `preDeletion` backup first. If the backup fails, nothing is deleted and the message says so. The repository refuses to delete a note that is not in Recently Deleted. Folder removal moves notes to Notes and does not require a backup, because nothing is erased.
- **Why:** the plan requires a verified backup before permanent deletion.

## D-020 — Version 3 adds rich body fields; the plain-text column stays the search text

- **Date:** 2026-10-16
- **Decision:** `JAASNotes 3.xcdatamodel` adds `Note.contentFormatVersion` (0 = plain, 1 = rich), `richTextData` (RTF), and `checklistData` (JSON sidecar). `bodyPlainText` is kept and holds the text derived from the RTF. Search, previews, and the legacy reader read it. The payloads are ordinary attributes, not external binary storage.
- **Why:** external binary storage keeps large values in a sibling folder that a Store.sqlite-only copy would miss, so backups would be incomplete. Keeping `bodyPlainText` means list rows and search never decode RTF.
- **Consequence:** a rich note's search text is refreshed on every rich save. Version 3 is not released; a released version would need a new model version instead.

## D-021 — Rich bodies are stored in precomposed (NFC) form

- **Decision:** `RichTextCodec.content(from:checklist:)` derives the stored text from the RTF it writes. Because RTF stores precomposed text, combining sequences become single characters. Checklist ranges are remapped to the same paragraph in the stored text.
- **Why:** the RTF writer does this itself. The probe showed `e` plus U+0301 comes back as U+00E9. Refusing such text would block ordinary typing, and keeping decomposed text would need a custom RTF encoder.
- **Consequence:** the first rich save of a plain note can change its combining sequences. The text looks the same. The plan's lossless rule is kept for plain notes and for every other character (emoji, CJK, RTL, and all control characters round-trip). Tests compare Unicode scalars, not `String ==`, which treats canonically equivalent text as equal.

## D-022 — Plain-text saves never discard formatting; damaged formatting is never overwritten

- **Decision:**
  - `updateNote` refuses any note with `contentFormatVersion != 0` (`richContentRequiresRichUpdate`).
  - `updateRichNote` refuses a note whose stored formatting cannot be read (`richContentUnreadable`).
  - `body(of:)` reports damaged formatting as `.unreadable(fallbackText:reason:)` and changes nothing.
  - `makeRecoveryCopy(of:)` creates a new plain note in the same folder from the fallback text. The original is not changed.
- **Why:** the plan requires that unsupported or corrupt rich data never overwrite the stored original. A plain save would silently drop formatting.
- **Consequence:** no UI calls these paths yet (03-02 wires the editor). A recovery copy is only offered for unreadable notes, never for notes that open normally.

## D-023 — Upgrades accept any prior version, not only version 1

- **Decision:** `LibraryMigrationService.priorModelNames` lists `JAASNotes 2` and `JAASNotes`. The source model found by compatibility check is used for the pre-upgrade backup, the upgrade, and the row comparison. The version-1-only pin check is removed; the row comparison already covers pins.
- **Why:** once version 3 is current, a version-2 library would otherwise be refused as foreign. Version 2 was written by the owner's Stage 2 builds, so it must upgrade.
- **Consequence:** the version-2 fixture is generated in the test from the version-2 model, not embedded. Its schema is the same, but a real library written by the owner's Stage 2 build has not been tested here.

## D-024 — Formatting is applied through the text view's own actions; a plain note becomes formatted on its first command

- **Decision:**
  - Bold, italic, underline, headings (size and bold), and bulleted lists are `NoteTextView` actions reached through the Format menu. Every action registers undo through `shouldChangeText` and `didChangeText`.
  - A plain note stays plain until a formatting command runs on it. Typing and pasting into a plain note keep it plain, because the view is not rich until then.
  - Headings are font size and weight, not a semantic heading attribute. Bullets are `NSTextList` paragraph styles.
  - Edits to a formatted note are refused until its body has loaded, and to any note whose formatting cannot be read.
- **Why:** the native text system gives undo, input methods, and selection behavior for free. Keeping plain notes plain means a paste cannot add formatting that a plain save would silently drop.
- **Consequence:** a heading in another app's RTF is not recognized as a heading here. Only what the Format menu creates is a heading. Recovery copies and the portable export of unsaved drafts carry plain text only.

## D-025 — Checklist items follow paragraphs, and every edit rule is a pure function

- **Decision:** `ChecklistEditing.apply` maps an edit (range and replacement) to the new checklist. Items are matched to paragraphs by paragraph index, not by stored offsets.
  - Typing, deleting, and pasting inside an item keep its ID and checked state.
  - Return or a paste with line breaks inside an item keeps the identity on the part that keeps the item's text. Each new line after the break is a new, unchecked item.
  - Joining two paragraphs keeps the first one's identity if it is an item. The second item is removed.
  - Deleting a whole item removes it. Its text goes with it, and the next item keeps its identity.
  - A break at the start of an item leaves a new, unchecked item above, and the original item keeps its text and state below.
- **Why:** a pure function can be tested for every rule without a view, and the editor and the tests share one definition. Matching by paragraph, not by stored offset, means positions are recomputed from the text.
- **Consequence:** joining an item with a plain paragraph before it removes the item. This is the rule, not a loss of data: the item's text stays in the joined paragraph.

## D-026 — Checkboxes are views beside each item, not characters; undo covers both text and checklist

- **Decision:**
  - Each checklist item has an `NSButton` checkbox positioned at its paragraph's first line. Checklist paragraphs have a 24-point left indent, so boxes never cover text. The checkboxes are listed in the text view's accessibility children, so VoiceOver and the keyboard can reach them.
  - Checklist state is never written into the RTF. The sidecar holds it (D-020).
  - Each text edit that changes the checklist registers a checklist undo step alongside the text's own undo step. Undo and redo restore both, and while the text system is undoing, the checklist is not recalculated from the edit.
  - Commands: Format > Checklist (Shift-Cmd-C) adds or removes items on the selected paragraphs. Format > Check or Uncheck Item (Shift-Cmd-Return) toggles the paragraph at the insertion point.
- **Why:** the RTF writer does not keep custom attributes (D-020), and drawn characters are not controls. A real control gives a state value and a label to assistive technology.
- **Consequence:** the checkbox layout is measured from the text layout. It was checked in a screenshot, not on every macOS release or with other text sizes. Bullet lists and checklists on the same paragraph are not supported. The checklist indent overrides the bullet indent.

## D-027 — Attachment bytes live beside the store; the row commits only after the bytes are in place

- **Decision:**
  - Payloads are copied to `Library/Attachments/<UUID>/payload`. Only metadata is in Core Data.
  - Import copies into staging while hashing and counting bytes, flushes, moves into place, then commits the row. A failed commit removes the moved bytes. An interruption leaves bytes with no row, and reconciliation moves those folders into `Recovery/orphaned-attachments/`.
  - Attaching does not change the note's revision or `modifiedAt`, so an open editor's next save is not a conflict.
  - Trashing keeps attachments. Permanent deletion removes the rows (cascade) first, and only then the payload folders, best effort.
  - The limit is 100 MiB per file, checked before copying and again while copying. It is provisional, as the plan says.
- **Why:** the store and the file system cannot share one transaction. The order of operations means a row never points at bytes that were not written, and nothing is deleted that might still be needed.
- **Consequence:** backups and restores copy the attachment folder with the store. Restores of backups made before version 4 have no attachments folder and that is fine. A library moved by migration copies the folder into the candidate, so an upgrade cannot drop attachments. No version 3 library can contain attachments, so that path is only exercised in future upgrades.

## D-028 — The portable archive is a validated folder package; import always creates new identities

- **Decision:**
  - A `.jnarchive` folder holds `manifest.json` (format name, version, counts, and a SHA-256 for every other file), `archive.json` (folders, notes, base64 RTF, checklists, attachment metadata), and `attachments/<UUID>/payload`.
  - Reading checks everything before anything is written: the format and version (only version 1 is read), every listed file's checksum and size, that no file is unlisted, that no path is unsafe, that no link is present, that rich text and checklists validate, and that IDs are unique.
  - Import gives every folder, note, and attachment a new identity. Archive folders named like existing ones get " (Imported)" and then " (Imported n)". The archive's Notes folder becomes "Notes (Imported)", so it never merges into the library's Notes. The review sheet lists the counts and every rename before anything is written.
  - All rows are written in one transaction. Attachment bytes are copied in beforehand; if the transaction fails they are removed.
  - Plain text and RTF files import as one note each. Plain text carries no formatting. Exported plain text puts the title first, and RTF keeps formatting only for rich notes.
- **Why:** archives must be validated completely before the first write, and a failed import must leave nothing visible. New identities mean an import can never overwrite a note.
- **Consequence:** importing the same archive twice creates two copies, by design. Archive format version 1 is frozen once released; later versions need a new version number and a reader for the old one.
