# JAASNotes — implementation plan and agent instructions

## 1. Mandate and decisions

JAASNotes is an independent, open-source, native macOS notes application. Use Apple Notes as a usability reference for a folder sidebar, note list, and editor. Create original branding, assets, and implementation. Never access, modify, or depend on Apple Notes databases or private APIs.

This document is a planning deliverable. No application has been implemented or tested. Begin implementation only when the owner requests it. Every checklist entry starts NOT COMPLETE.

Confirmed by the owner:

- Minimum runtime: macOS 14 Sonoma.
- Storage: an app-managed local library, rather than a directory of externally editable notes.
- Native desktop application; prefer Swift, SwiftUI, and Apple frameworks.
- Stage 1 must include the full core workflow, including persistent autosave and Recently Deleted.

Recommended defaults, which agents may implement without another product consultation:

- SwiftUI shell, AppKit text editor, Core Data with an SQLite store; no third-party runtime dependencies.
- One library and one main editing window initially. Reopening the main window retains the library. Settings and recovery sheets may be separate windows.
- Flat folders, a permanent default Notes folder, All Notes, and Recently Deleted. No nested folders initially.
- Separate editable note title and body; empty title displays “Untitled Note.”
- Deleted notes are retained indefinitely until explicit permanent deletion. No automatic expiration.
- Sandbox enabled from the beginning; local-only operation with no network entitlement.
- MIT is the recommended license, but confirm the owner's license choice before adding a license or publishing a repository. That decision does not block local development.

Substantial changes require an explicit decision recorded in `docs/decisions.md`: switching storage engines or document formats, lowering the OS floor, adding external dependencies, enabling network/cloud services, changing retention, supporting concurrent library writers, or adopting a different distribution model. Ask about the consequence, not just a technology preference.

The owner's exact macOS release, chip, and installed Xcode are unknown. Choosing a macOS 14 deployment target does not establish that their Mac can run a particular Xcode release. Before implementing, ask for About This Mac's macOS version and chip and the installed Xcode version. Do not prescribe an OS upgrade or assume Apple Silicon. RAM/storage information is needed only if an actual development constraint arises.

## 2. Scope and priorities

Priority order: preserve user data; make failures understandable and recoverable; support native workflows and accessibility; then add features and visual polish.

Stage 1 delivers a runnable `.app` with note creation, editing, soft deletion and restoration; folder creation and rename; moving notes; title/body search; autosave; close/relaunch persistence; system appearance; native menus and shortcuts; basic backup and recovery. It is a plain-text editor, not a temporary in-memory prototype.

Stages 2–4 add organization, rich text and checklists, attachments, interchange, and release readiness. Every completed stage must remain runnable and preserve all earlier behavior and data.

Explicit exclusions from these four stages: cloud sync, collaboration, accounts, AI, locked/password-protected notes, custom encryption, iOS/web/Windows clients, handwriting/OCR, audio recording, scanning, plugins, browser clipping, reminders, nested folders, automatic updates, and Apple Notes database integration. Those are separate future proposals. FileVault and OS account protections are not an app-level encryption feature. Do not advertise encrypted notes.

## 3. Stack, tools, and architecture

| Component | Choice and rationale |
| --- | --- |
| Language | Swift; start with Swift 5 language mode for broad Xcode compatibility, enable complete concurrency checking, and resolve warnings in new code. A later Swift 6 language-mode change is a separate reviewed task. |
| UI | SwiftUI `NavigationSplitView`, standard lists, toolbars, sheets, Settings, commands, and semantic colors. |
| Editor | `NSTextView` in `NSViewRepresentable`, initially plain text. Supports native selection, undo, spelling, input methods, and later attributed text without replacing the editor. |
| Persistence | `NSPersistentContainer`, versioned Core Data model, SQLite/WAL. Explicit save boundaries, migration tools, and tested snapshot handling suit the reliability requirements. |
| Why not SwiftData initially? | It is viable on the selected OS floor, but Core Data offers established explicit store/migration control. This is a project-specific preference, not a claim that SwiftData is inherently unreliable. |
| Files | Foundation `FileManager`; user-selected file access via AppKit panels; UniformTypeIdentifiers; CryptoKit SHA-256 for attachment/backup validation when needed. |
| Tests | XCTest for unit, SQLite integration, and XCUITest flows. Avoid adding test frameworks. |
| Build | Committed Xcode project, shared JAASNotes scheme, app/unit/UI-test targets. No CocoaPods, Carthage, XcodeGen, server, Node, or Python required to build the app. |
| Diagnostics | `Logger`/OSLog with metadata only. Never log note text, titles, attachments, or full user paths. |

Set `MACOSX_DEPLOYMENT_TARGET = 14.0`. Xcode 15 with the macOS 14 SDK is the feature/toolchain floor for this plan. Prefer a stable Xcode supported by the actual development Mac, confirm it against Apple's current compatibility matrix, and record the exact tested release and Swift compiler in README and CI. Do not require a beta. Newer SDKs do not require raising the deployment target; guard newer APIs or avoid them. Validate Intel support if shipping x86_64; never infer it from an arm64 build. Aim for a universal binary if supported by the selected release toolchain and testing resources.

Full Xcode is needed, not only Command Line Tools. Local build/run must not require a paid developer membership. Signing configuration may need local adjustment; never commit a personal team identifier or credentials. Public Developer ID signing/notarization requires a separate distribution setup and owner authorization. An unsigned local build is not a notarized release.

Use a modest layered architecture:

1. SwiftUI views render state and dispatch actions. No store writes or filesystem operations inside view bodies.
2. `@MainActor` application/editor state owns selection, focus, editable drafts, dirty revision counters, and error presentation. It does not own the durable truth.
3. Use-case services implement create, move, trash, restore, search, save, and backup policies.
4. Repositories expose value-type snapshots and typed errors. A serial writer uses a private Core Data context through `perform`; read contexts are read-only and merged after commits.
5. Persistence and file services encapsulate Core Data and filesystem APIs. Never pass managed objects across queues; pass UUIDs, object IDs where appropriate, or immutable values.

Use one writer and explicit transaction boundaries. A database save must reach the persistent store, not merely a child context. Use error-on-conflict behavior initially; never silently overwrite a conflicting revision. The repository checks expected revision and increments revision on success. All mutations, backups, and migrations go through the same coordination boundary. Do not introduce a generic framework, dependency-injection container, or event bus. Constructor injection of a repository, clock, filesystem adapter, and failure injector is sufficient.

## 4. Proposed repository structure

The following paths are to be created during implementation, not by this planning task.

```text
JAASNotes.xcodeproj/
JAASNotes/
  App/                 App entry, AppDelegate, composition, Commands, window lifecycle
  Domain/              Note/Folder snapshots, identifiers, validation, use-case protocols
  Features/
    Library/           Three-column shell, selection, sidebar, folders
    NoteList/          Rows, previews, dates, ordering, empty states
    Editor/            Draft state, NSTextView adapter, focus, undo integration
    Search/            Query state, scope, cancellation, result mapping
    Recovery/          Save-error, store-open failure, backup/restore screens
    Settings/          Appearance, backup status, later preferences
  Services/            AutosaveCoordinator, LibraryService, BackupService
  Persistence/
    CoreData/          Container, repository, managed-object mapping, migrations
    JAASNotes.xcdatamodeld/  Immutable released model versions
    Files/             Library paths, atomic writes, later attachment store
  Resources/           Original assets, localization, entitlements
JAASNotesTests/
  Unit/                Pure rules and autosave state-machine tests
  Integration/         Real temporary SQLite stores, migrations, backup/recovery
  Fixtures/            Synthetic older stores, text samples, attachment fixtures
JAASNotesUITests/      End-to-end workflows and keyboard checks
docs/
  decisions.md         Architecture choices and approved changes
  progress.md          Substage evidence and remaining limitations
  storage.md           Schema, file layout, recovery and migration procedures
  testing.md           Repeatable manual matrix and failure-injection instructions
README.md              Setup, build, run, feature status, privacy and limitations
CONTRIBUTING.md         Contributor workflow and verification expectations
LICENSE                Only after owner chooses license
AGENTS.md              This plan and the authoritative ordered checklist
```

Create components only when their stage needs them. No empty speculative implementations. Repository fixtures contain synthetic data only; exclude DerivedData, result bundles, user libraries, credentials, and personal Xcode settings from git.

## 5. Data model and invariants

### Version 1, implemented in Stage 1

| Entity | Fields and rules |
| --- | --- |
| LibraryMetadata | Single record: `libraryID: UUID`, `createdAt: Date`, `formatVersion: Int`. Core Data model metadata controls schema migration; formatVersion does not replace it. |
| Folder | `id: UUID`, `name: String`, `normalizedName: String`, `createdAt`, `modifiedAt`, `isDefault: Bool`. Unique UUID and normalized name. Exactly one default folder. |
| Note | `id: UUID`, `title: String`, `bodyPlainText: String`, `createdAt`, `modifiedAt`, `deletedAt: Date?`, `revision: Int64`, required `folder` relationship. Unique UUID; revision increments for every committed mutation. |

Use UTC instants in storage and localized display dates. Validate names by trimming surrounding whitespace and normalizing case/diacritics consistently; reject empty or duplicate folder names with an inline message. Keep display spelling. Reserve the visible names of virtual folders. A note title may be empty or duplicated. Store Unicode text losslessly, including emoji and non-Latin input.

All Notes and Recently Deleted are virtual queries, not real Folder rows. All Notes includes every nondeleted note. Recently Deleted includes only `deletedAt != nil`. The default Notes folder is real, cannot be renamed or deleted, and is the fallback destination. No folder deletion in Stage 1. Folder-to-note delete rule is Deny; do not cascade-delete notes when adding folder removal in Stage 2.

Soft-delete changes `deletedAt`, increments revision, and keeps the original folder relationship and all content. Restore clears `deletedAt`. Trash and restore do not change content `modifiedAt`; ordering in trash uses `deletedAt`. Content edits and moves update `modifiedAt`; viewing, searching, saving identical data, and renaming a folder do not. These are explicit product policies and must be tested.

### Later model versions

Stage 2 adds `isPinned: Bool = false`; sorting preferences live in UserDefaults, not note records. Removing a user folder atomically reassigns all its active and deleted notes to the default folder before deleting the folder; explain this in confirmation UI.

Stage 3 adds `contentFormatVersion`, `richTextData: Data?`, and `checklistData: Data?`. Use standard RTF for supported formatting and a small versioned Codable checklist sidecar with stable item UUIDs, checked state, and validated UTF-16 paragraph ranges. Define editing transforms for insertions/deletions/splits/merges; UTF-16 ranges must never split a composed character. Checklists are paragraph semantics with an accessible control, not just decorative Unicode boxes. RTF cannot be assumed to preserve custom checklist attributes. Persist RTF, checklist state, and a derived plain-text search representation in one transaction. Unsupported or corrupt rich data must not overwrite the stored original: open a recovery copy with plain-text fallback and surface the issue. Convert v1 text lazily on first rich edit or through a tested migration; do not rewrite every note just because the app launched.

Stage 4 adds Attachment: `id`, owning note relationship, `originalFilename`, `contentType`, `byteCount`, `sha256`, `relativePath`, `createdAt`, and display order. Store file bytes separately. Begin with an attachment tray below the editor, avoiding inline attachment serialization complexity. Do not store absolute source paths or depend on the original file remaining available.

## 6. Persistence, autosave, and recovery contracts

### Library location

Resolve the sandbox's Application Support URL through Foundation, then append `JAASNotes`. Do not hard-code the user's home directory or container UUID. Use a stable bundle identifier (provisional `org.jaasnotes.JAASNotes`; verify ownership before distribution) from the first persisted development library. Changing signing identity, sandboxing, or bundle ID later needs an explicit data-location migration.

```text
Application Support/JAASNotes/
  Library/Store.sqlite          Core Data-owned SQLite store
  Library/Store.sqlite-wal      Core Data-owned WAL when present
  Library/Store.sqlite-shm      Core Data-owned shared-memory file when present
  Library/Attachments/<UUID>/payload   Stage 4 immutable copied bytes
  Backups/<timestamp-UUID>/     Complete validated snapshot packages
  Recovery/                    Explicitly preserved failed stores/drafts
  Staging/                     Temporary imports, snapshots, migrations
```

Core Data owns its schema and journaling. Never issue raw SQL against its tables, edit its files, or copy only Store.sqlite while it is open. Treat preferences and disposable caches separately. Do not put the live database in iCloud Drive, Dropbox, or a shared/network folder. External backups may be copied to a user-chosen location.

### Save state machine

- Each edit updates the in-memory draft immediately and increments a draft revision. Display Unsaved, Saving, Saved, or Save Failed truthfully.
- Debounce for approximately 500 ms after input; during continuous typing commit at least every 2 seconds when storage is healthy. Snapshot the exact title/body/revision being saved.
- Serialize commits. If edits arrive during a save, retain them and schedule the next save. An older completion must never mark newer edits saved or overwrite the current draft.
- Successful persistent-context save is the acknowledgement boundary. Only then advance the committed revision and show Saved. Automatic saving does not mean every keystroke is already durable.
- Flush on switching notes, moving/trashing a dirty note, window close, ordinary Quit, and before backup/migration. Backgrounding triggers a best-effort flush. Compose flushes through the coordinator rather than writing independently.
- A failed flush blocks a selection-changing/destructive action until Retry, Cancel, or explicit export/discard resolution. The draft remains editable/copyable and is never cleared by a fetch refresh.
- Preserve editor selection, scroll, undo history, and marked text during SwiftUI updates. Do not reset `NSTextView.string` on every render. Avoid serializing provisional input-method composition as if it were finalized.
- Use AppKit termination delegation to delay ordinary Quit while flushing, then reply once. On failure offer Retry, Cancel Quit, and Save Recovery Copy. Discard requires explicit confirmation. Window close uses the same dirty-state policy.
- Cmd-S requests an immediate flush; it does not create a different storage path. Folder mutations, move, trash, and restore save immediately as atomic transactions; show success only after commit.

Normal close/relaunch must preserve all edits. A crash/force-quit may lose edits since the last acknowledged commit (normally up to the save interval); force-quit and power failure cannot be intercepted reliably. Document this limit. Do not claim zero data loss under storage failure. A recovery file is only helpful if it was actually written successfully.

### Failure behavior

Injectable failures must cover disk-full, permission denial, write failure, malformed store, unsupported model version, backup interruption, and migration interruption. Show a persistent actionable error with sanitized details. Retain unsaved memory drafts, permit text selection/copy, and offer a user-selected recovery export; surface failure of that export too. Never swallow errors with `try?`, auto-create an empty replacement library after a store-open failure, or clear dirty flags on failure.

On store-open failure, show a recovery window instead of the normal editor: Retry, restore a validated backup, export/copy diagnostic metadata, or explicitly create a separate new library after preserving the old one. Never delete the original to make startup succeed. If the store is unreadable, do not promise content export from it. Readable content may be salvaged into a separate library; never repair in place without a verified preserved source.

### Backups, already required in Stage 1

Provide Back Up Now and Restore Backup controls, last successful backup date, and visible backup failures. After a library has changed, create at most one automatic snapshot per day while the app is active; also snapshot before every migration, restore, and permanent-delete operation. Keep the latest seven successful automatic snapshots initially. Manual snapshots are not automatically pruned. Delete older snapshots only after a new one validates; pre-operation snapshots remain until the operation succeeds. Same-disk backups help with mistakes but not disk loss, so permit copying a complete backup package to a user-chosen external location.

Implement a simple quiesced snapshot first: pause mutations, flush the writer, close/detach all contexts and the store cleanly, copy the complete library directory into staging, then reopen the live stack. Maintain the writer lock through copy/reopen. Never copy a live WAL set with ordinary FileManager operations. Alternatively use an Apple-supported persistent-store copy API, but only after validating the exact API semantics and tests. Filesystem operations alone do not make a multi-file live store snapshot consistent.

Each snapshot contains a manifest with backup-format version, library ID, app/schema version, timestamp, counts, and file checksums. Validate the copied store using an isolated container with migration disabled, check relationships and note counts, and later check attachment checksums. Only after validation atomically rename the staged snapshot to its final name. Interrupted staging packages are not listed as valid backups. Always reopen the live store or show an explicit recovery state if reopening fails.

Restore validates the candidate before replacing anything, warns that current contents will be replaced, snapshots the current library if readable, closes the store, and performs a recoverable swap. Preserve the previous directory until the replacement opens and passes validation. Use a small restore transaction marker and startup recovery logic so a crash between directory renames cannot strand both copies. An unsupported/newer-format backup must be rejected without modifying current data. Test restoring into a fresh temporary location as well as replacing a populated library.

### Migration policy

Check store metadata before writable open. Refuse future/unknown models with an explanation; never reinterpret them as empty stores. Never edit a released `.xcdatamodel` in place. Add a model version, keep all prior models, and document field defaults and transformations. Simple compatible changes may use lightweight migration; custom transformations require an explicit migration implementation and fixtures. Disable blind automatic migration of the only live copy.

Before migration, preserve a consistent source snapshot. Migrate a staged copy, validate entity counts, IDs, relationships, rich text, and attachments as applicable, then use the recoverable swap procedure. Keep the source backup. Failed migration leaves the original usable by its compatible app version. Downgrades are unsupported unless a separately tested reverse path exists. Deliver fixture tests from every released version to the current version.

### Attachments and cross-resource atomicity, Stage 4

Import bytes into staging using a generated UUID, validate size/type, hash, and close the file, then atomically move to an immutable destination on the same volume before committing the Attachment row. A crash can leave an unreferenced file; it must not create a committed row pointing to bytes never written. A failed DB commit retains or quarantines staged/final bytes until reconciliation. Never overwrite attachment payloads in place; replacement gets a new UUID.

Metadata and filesystem cannot share one Core Data transaction. Add a reconciliation pass that reports missing referenced files and quarantines unreferenced payloads before any delayed cleanup. Do not delete files merely because one query failed. Trash retains attachments; permanent deletion commits metadata removal first, then attempts file cleanup, which is safely retryable. Backups hold the mutation lock across both store and attachment capture. Never follow imported symlinks or trust archive paths containing traversal. User-selected files are copied within their allowed access scope; no persistent source bookmark is needed for a completed copy.

## 7. Interface and essential workflows

Three resizable columns: folders; note rows with title, up to two preview lines, and localized modification date; selected-note editor with title, body, and compact save status. Respect system light/dark appearance by default. Use native fonts, semantic background/text colors, selection styling, and SF Symbols where appropriate; design an original JAASNotes icon later. Do not hard-code an Apple Notes color scheme or copy its assets.

- First launch creates metadata and the default Notes folder once, transactionally. Show an empty-state New Note action; do not add demo notes to a user's library.
- New Note in a user folder uses that folder. From All Notes or Recently Deleted, use Notes, clear the search, select the new active note, and focus its title. Empty notes remain until the user deletes them.
- Rename a folder via menu/context menu or keyboard-accessible sheet; reject invalid input without closing the sheet.
- Move a note through a Move To menu/sheet in Stage 1. Drag-and-drop is optional Stage 2 polish, never the only way.
- Normal Delete moves the note to Recently Deleted. Select an adjacent row predictably and announce the change. Recently Deleted shows deletion date, read-only content, Restore, and a confirmed Delete Permanently action. Restoring returns the note to its preserved folder or fallback Notes folder.
- Permanent deletion and Empty Recently Deleted require explicit confirmation and a successful pre-operation backup; if backup fails, cancel the destructive operation. These controls may be deferred to Stage 2, but Stage 1 must have soft-delete and Restore and must never purge automatically.
- Search is literal, case/diacritic-insensitive substring matching over title and body, with safely bound predicates. Global active notes is the default search scope; provide a visible current-folder scope. Trash is searched only when Recently Deleted is explicitly selected. Folder names and attachment bytes are not searched.
- Debounce search by about 200 ms, cancel/discard stale results with generation tokens, and preserve Unicode. Queries must not move focus or hide the currently edited draft unexpectedly. Overlay the current draft in results until committed; database matches alone must not erase pending text. Empty query restores the normal list.
- Stage 1 order: modified descending, UUID as a stable tie-breaker. Freeze row repositioning while actively editing the selected note; apply ordering after flush/focus departure so typing does not jump the list. Stage 2 adds pinned-first ordering and user-selectable modified/created/title sorting.
- Closing the window flushes changes but follows standard Mac app lifecycle. Dock activation or a menu command reopens the main window. Remember valid selection and column widths; missing IDs fall back safely.

### Menus, shortcuts, and accessibility

| Action | Default shortcut / behavior |
| --- | --- |
| New Note | Cmd-N |
| New Folder | Shift-Cmd-N |
| Search notes | Shift-Cmd-F; focus global search |
| Find within note | Cmd-F using native text-finding behavior |
| Save now | Cmd-S |
| Move selected note to trash | Cmd-Delete when note-list commands are targeted; never intercept text deletion in the editor |
| Undo / Redo | Cmd-Z / Shift-Cmd-Z; native text undo, repository-aware structural undo only where implemented |
| Settings / Close / Quit | Cmd-comma / Cmd-W / Cmd-Q |

Provide standard JAASNotes, File, Edit, View, Window, and Help menus. Keep cut/copy/paste/select-all/spelling and text-navigation commands on the responder chain. Menus disable invalid actions and show shortcuts. Folder rename, move, restore, column visibility, and backup controls must be reachable without a mouse even if they have no dedicated shortcut.

Tab/Shift-Tab move predictably among sidebar, list, title, and body; arrow keys navigate rows; Return activates a selection/action where conventional; Escape dismisses sheets/search without discarding edits. Test macOS keyboard navigation settings. Label icon buttons and expose selected row, note title, save failure, checklist checked state, and recovery status to VoiceOver. Do not announce Saved after every keystroke. Use adequate contrast, visible focus, scalable text, Reduce Motion support, and no color-only state. Validate long titles, large text, narrow windows, right-to-left input, and composed text. A real VoiceOver walkthrough is required; screenshots do not prove accessibility.

## 8. Build, run, and verification instructions

These commands describe the intended project after Stage 1 scaffolding. They are not claims of completed builds. Run from the repository root with full Xcode selected:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project JAASNotes.xcodeproj
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/JAASNotes.app
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-01.xcresult test
```

Use a new result-bundle path on repeat test runs. For GUI development, open the Xcode project, select JAASNotes → My Mac, then Cmd-R. If Xcode selection or signing needs changing, explain the precise local adjustment; do not silently alter the machine's global configuration. Record the actual tested commands after project creation. Do not use signing-disabled builds as proof of a working sandboxed distribution artifact.

Tests must use uniquely created temporary libraries through injected paths. UI tests must accept a test-only library root and deterministic fixture selection, gated to test/debug configuration. Never erase or mutate the real library. Persistence tests must use disk-backed SQLite: in-memory Core Data tests cannot establish restart durability or WAL/migration correctness.

Stage 1 verification matrix:

1. Create two folders and several notes with Unicode titles/bodies; rename a folder; move a note; search title and body; clear search. Verify folder counts and exclusion of deleted notes.
2. Type and immediately switch notes, close the window, reopen, quit, and relaunch. Verify the complete last edits and folder assignment each time.
3. Delete, quit, relaunch, restore; verify content, UUID, timestamps policy, and folder preservation. No automatic purge.
4. Use a delayed fake writer to complete an old save after a newer edit; verify dirty status remains and newer text eventually persists. Use an injected clock rather than timing-sensitive sleeps.
5. Inject save failure; verify visible error, retained draft, retry, recovery export, and canceled quit. Clear the failure and prove recovery without duplicate notes.
6. Force-terminate after a confirmed save and reopen the same SQLite library; committed content must remain. Test termination during pending save and document the permitted uncommitted window.
7. Back up, modify, and restore into a separate library; compare IDs and content. Interrupt snapshot and restore at each boundary; startup selects/recoverably offers the preserved complete copy.
8. Open a corrupt and a future-schema fixture; verify no replacement/erasure and a useful recovery UI.
9. Exercise menu and keyboard-only creation/edit/move/delete/restore; run VoiceOver, light/dark, long text, and input-method checks.

Add focused tests in later stages for folder removal, pin/sort persistence, rich-text/checklist round trips, every schema upgrade, attachment interruption and reconciliation, and malformed/oversized imports. Set an initial performance dataset of 10,000 small synthetic notes; record search and launch timings on the actual test Mac, with a provisional under-500-ms search response target after debounce. Avoid loading every body into the visible list; fetch summaries in batches and measure. Do not promise performance on hardware not tested. Keep expensive file work off the main actor.

CI should build and run unit/integration tests on a macOS runner using a pinned available Xcode. Run UI tests where the runner supports a GUI session. Record macOS 14 runtime testing separately from compiling with a 14.0 deployment target. If no macOS 14 machine/VM is available, report that gap instead of claiming compatibility verified. Manually run accessibility checks and release smoke tests on supported hardware before publication.

## 9. Four-stage roadmap and stage gates

### Stage 1 — dependable local plain-text app

Build the app shell, version-1 persistence, complete core workflows, autosave/error handling, trash recovery, backup/restore, menus, and accessibility. This is intentionally the largest stage: do not reduce it to a mockup to make the milestone appear smaller. Implement it through the small substages at the end of this file. Keep a runnable shell after scaffolding and integrate each completed substage behind working navigation.

Exit gate: a fresh checkout builds a real app; every Stage 1 verification flow passes on the recorded environment; notes survive ordinary close/relaunch; delete/restore survives relaunch; failures retain drafts and never replace a store; backup restoration is proven. No rich-text or attachment work begins before this gate.

### Stage 2 — organization and recovery polish

Depends on Stage 1. Add pinned notes, sort controls, safe folder deletion, confirmed permanent deletion/empty trash, and mature recovery/settings UI. Validate the first schema migration with real v1 fixtures. Keep retention indefinite by default. Drag-to-move may be added only after the accessible menu path works.

Exit gate: v1 libraries upgrade without changed note IDs/text; pin/sort preferences survive relaunch; removing a folder preserves active and deleted notes; destructive actions require backup/confirmation; all Stage 1 regressions pass.

### Stage 3 — rich text and checklists

Depends on Stage 2. Add bold/italic/underline, headings, basic lists, and accessible checklist toggles through the existing NSTextView bridge. Define and test RTF/checklist serialization before exposing formatting controls. Keep title as plain text and plain-text search derived from the canonical rich body. Native undo must include formatting and checklist changes without autosave destroying undo history. Do not add tables, arbitrary HTML, or inline file embedding.

Exit gate: legacy text notes remain editable; supported formatting and checklist identity/state survive edit/save/restart/backup/restore; Unicode edits and paragraph operations preserve checklist associations; searches still match visible content; corrupt rich content does not overwrite originals.

### Stage 4 — attachments, interchange, and release readiness

Depends on Stage 3. Add copied image/file attachments in a tray with thumbnails where supported, safe open/export actions, missing-file UI, reconciliation, and attachment-aware backups. Provisional import limit: 100 MiB per file with clear rejection before copying; document and revisit based on measured needs. Never execute imported files automatically.

Add plain-text import/export, RTF import/export with documented checklist limitations, and a versioned JAASNotes portable archive containing a manifest, folders, notes, rich payloads, checklist metadata, attachment bytes, and checksums. A portable archive is distinct from a Core Data backup. Plain text loses formatting; tell the user. Native archive round trips must preserve supported semantics. Imports create new IDs by default and remap relationships; do not overwrite matching notes. Validate all content in staging before a coordinated import; cancel without partial visible imports. Present folder/name collisions and counts before committing. Reject unsupported versions, path traversal, symlinks, decompression bombs, and missing payloads.

Finish original icon, README, contributor guidance, chosen license, privacy description, release build, and distribution notes. Public publication, release upload, signing/notarization credentials, and payment are not authorized by this plan; prepare a reviewable artifact and ask before external release when implementation reaches that point.

Exit gate: attachment bytes survive original-file removal and app restart; portable archive round trip reproduces content in a fresh library; interrupted import leaves no partial visible import; all prior regression gates pass; release limitations and supported/tested environments are stated accurately.

## 10. Agent operating rules and evidence

- Read this file and the current progress/decision logs before changing code. Inspect the repository; do not assume files in this proposed tree exist.
- Work in checklist order unless dependencies permit a small independent task. Do not implement optional future work to avoid a difficult reliability requirement.
- Keep diffs focused and the app runnable. Run the narrow meaningful tests for each change, then the stage gate at milestone completion. Do not add tests that merely restate implementation details.
- Never use production user data for tests, previews, demos, migrations, or failure injection. Use synthetic fixtures and temporary roots.
- Never reset/delete a store as a “fix,” silently change serialization, raise the deployment target, or add a network/dependency requirement.
- Record each substage in `docs/progress.md`: ID, date, changes, exact build/test commands, environment, result, fixture/scenario evidence, remaining risks, and relevant commit identifier when available. Use pass/fail/not run accurately.
- Update a checklist entry to `[COMPLETE]` only when its stated proof exists; partial work remains `[NOT COMPLETE]` with details in progress.md. Do not delete or renumber IDs. Add future work with new IDs through an approved plan update.
- A successful compile alone proves neither persistence nor recovery. A saved screenshot proves neither keyboard access nor VoiceOver. Report any untested hardware/runtime claim explicitly.
- At each stage completion, summarize delivered behavior, tests, known limitations, and the next dependency. Request owner input only for material product decisions, inaccessible environment facts, or genuinely needed authorization.

## 11. Primary references

Use official documentation and verify availability against the chosen SDK during implementation. Sources below inform the framework and reliability decisions; the detailed policies above are JAASNotes design choices.

- Apple Xcode system/SDK/deployment compatibility: https://developer.apple.com/xcode/system-requirements
- SwiftUI navigation migration and OS availability: https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types
- Core Data overview and persistence APIs: https://developer.apple.com/documentation/coredata
- Core Data model versioning and migration: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/Introduction.html
- SQLite WAL and safe store handling, QA1809: https://developer.apple.com/library/archive/qa/qa1809/_index.html
- AppKit termination delegate: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)

## 12. Ordered implementation checklist

01-01: Confirm development macOS/chip/Xcode, record the compatible stable toolchain and macOS 14 deployment target, then create the Xcode app and test targets with a shared scheme and sandboxed three-column shell. Complete when the native app builds and opens on the owner's Mac and the environment is recorded. [COMPLETE]

01-02: Implement version-1 Note, Folder, and LibraryMetadata models, the isolated serial repository, stable library paths, and transactional first-launch initialization. Requires 01-01. Complete when SQLite integration tests verify invariants, one default folder, no duplicate initialization, and persisted data after stack recreation. [COMPLETE]

01-03: Implement note creation and plain-text title/body editing with stable selection and NSTextView integration. Requires 01-02. Complete when multiple notes can be created and edited, Unicode/IME input and native text undo work, and switching selections retains drafts. [NOT COMPLETE]

01-04: Implement revision-aware autosave, immediate save, navigation/close/quit flushing, status, retry, and recovery-copy export. Requires 01-03. Complete when latest edits survive normal restart and delayed/failed saves neither discard drafts nor falsely report Saved; failure can cancel Quit. [NOT COMPLETE]

01-05: Implement folder creation/rename, note moves, list previews/dates, stable default ordering, and empty states. Requires 01-04. Complete when these operations survive restart and invalid folder names or failed moves leave consistent data and selection. [NOT COMPLETE]

01-06: Implement literal title/body search, global/current-folder scopes, draft overlay, and stale-result cancellation. Requires 01-05. Complete when Unicode queries find title/body matches, deleted notes are excluded from active scopes, and rapid queries cannot show obsolete results. [NOT COMPLETE]

01-07: Implement persistent soft deletion, read-only Recently Deleted, and restoration with original-folder preservation. Requires 01-05. Complete when deleting, quitting, relaunching, and restoring reproduces note content/identity and nothing is automatically purged. [NOT COMPLETE]

01-08: Implement quiesced verified backups, retention, backup status, recoverable restore swaps, and store-open failure UI. Requires 01-04 and 01-07. Complete when a snapshot restores into a fresh library and interruption/corruption tests preserve the original without silently creating an empty store. [NOT COMPLETE]

01-09: Complete native menus, focus routing, shortcuts, light/dark behavior, accessible labels, and window reopening. Requires 01-06 through 01-08. Complete when keyboard-only and VoiceOver core workflows work and editor text-delete shortcuts cannot trash a note accidentally. [NOT COMPLETE]

01-10: Run the complete Stage 1 persistence/failure/UI matrix, add macOS CI, and document build/run/recovery instructions and measured limitations. Requires 01-01 through 01-09. Complete when the runnable plain-text app meets every Stage 1 gate with evidence and no unresolved data-loss defect. [NOT COMPLETE]

02-01: Add the version-2 pinned-note field and staged migration infrastructure with pre-migration backup and recoverable swap. Requires 01-10. Complete when v1 fixtures upgrade with preserved IDs/content and interrupted or unsupported migrations leave the original recoverable. [NOT COMPLETE]

02-02: Add pin/unpin and modified/created/title sorting with persisted preferences and stable tie-breakers. Requires 02-01. Complete when ordering is correct after restart and sorting does not move focus or overwrite unsaved edits. [NOT COMPLETE]

02-03: Add safe user-folder removal, confirmed permanent note deletion, and Empty Recently Deleted. Requires 02-01 and 01-08. Complete when folder removal rehomes active/deleted notes atomically and permanent deletion requires a verified backup and confirmation, with failure leaving data intact. [NOT COMPLETE]

02-04: Polish recovery/settings UI and rerun core regressions, migration tests, keyboard checks, and sorting performance checks. Requires 02-02 and 02-03. Complete when the Stage 2 app remains runnable and all organization/recovery acceptance criteria have recorded evidence. [NOT COMPLETE]

03-01: Define version-3 RTF/checklist serialization, plain-text derivation, validation, and legacy/corrupt-content handling. Requires 02-04. Complete when isolated round-trip and migration tests preserve Unicode, content, and legacy note IDs without overwriting unreadable originals. [NOT COMPLETE]

03-02: Add basic rich-text formatting, headings/lists, native commands, and editor undo integration. Requires 03-01. Complete when supported formatting survives autosave, relaunch, and backup/restore without selection jumps or broken undo. [NOT COMPLETE]

03-03: Implement accessible checklist controls and stable item/range transforms for edits, paragraph split/merge, paste, and undo. Requires 03-02. Complete when checked state and item identity survive these operations and restart, including emoji and non-Latin text. [NOT COMPLETE]

03-04: Integrate rich-content search/previews and execute Stage 3 regression, migration, failure, and accessibility gates. Requires 03-03. Complete when visible text remains searchable and all Stage 1–3 workflows pass in the runnable app with evidence. [NOT COMPLETE]

04-01: Add the Attachment model/migration, staged file-copy pipeline, hashes, reconciliation, and attachment-aware backup/restore. Requires 03-04. Complete when injected failures cannot produce an acknowledged missing payload and copied bytes survive source deletion, restart, and restore. [NOT COMPLETE]

04-02: Add the attachment tray, image previews, file open/export/removal, size validation, and accessible missing-file states. Requires 04-01. Complete when image and ordinary-file workflows work by keyboard and trashed notes retain their files until permanent deletion. [NOT COMPLETE]

04-03: Implement staged plain-text/RTF import/export and versioned portable archives with validation, collision review, ID remapping, and rollback/reconciliation. Requires 04-02. Complete when archive round trips preserve supported notes/folders/checklists/files in a fresh library and malformed/interrupted imports leave no partial visible import. [NOT COMPLETE]

04-04: Finish original branding, README/CONTRIBUTING, owner-confirmed license, release configuration, compatibility evidence, and the full regression matrix. Requires 04-03. Complete when a fresh checkout produces a runnable release build, all four stage gates pass or explicit environment gaps are documented, and a reviewable distribution candidate is ready without unauthorized publication. [NOT COMPLETE]
