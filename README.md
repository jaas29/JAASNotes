# JAASNotes

JAASNotes is an independent, native macOS notes app. It is in early development. This README describes what runs today, how to build it, and what is not finished.

## Status

- **Stage 1 (plain-text app): in progress.** Implemented: folders, notes, moves, search, autosave, Recently Deleted, backups and restores, store-open recovery, native menus and shortcuts.
- **Not finished:** the VoiceOver and keyboard-only walkthroughs, Stage 1's full verification matrix, and the Stage 1 CI run. See `docs/progress.md`.
- **Not built yet:** rich text, checklists, attachments, import and export, and any Stage 2 organization features.

## Requirements

- macOS 14 Sonoma or later (deployment target 14.0).
- Full Xcode, not only Command Line Tools. Tested with Xcode 26.3 (Swift 6.2.4 compiler, Swift 5 language mode) on an Apple M3 Pro running macOS 26.6.2. Other combinations are untested.
- No paid developer membership is needed for local builds.

## Build and run

```sh
xcode-select -p
xcodebuild -version
xcodebuild -list -project JAASNotes.xcodeproj
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/JAASNotes.app
```

Tests (use a new result bundle path for each run):

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-<n>.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 90 test
```

Signing: local builds use the project's signing settings. If Xcode reports a signing error, select a local team in the target's Signing settings. Do not commit a team identifier.

## Where your data lives

The library is an app-managed folder inside the app's sandbox Application Support folder:

```text
JAASNotes/Library/Store.sqlite      the notes database (Core Data, SQLite)
JAASNotes/Backups/<package>/        complete, checksummed backup packages
JAASNotes/Recovery/                 libraries moved aside by a restore or by "Create New Library"
JAASNotes/Staging/                  temporary copies; never listed as backups
```

Do not edit these files while the app is open, and do not put the library in a synced or shared folder.

## Backups and recovery

- **Back Up Now** and **Backups…** (toolbar) list valid backups, show the last backup date, copy a backup to a folder you choose, and restore one.
- An **automatic** backup is taken at most once a day, after the library changes.
- Before a restore, the current library is backed up if it can be read. The replaced library is moved into `Recovery/`, not deleted.
- If the library cannot open, the app shows a recovery screen: Retry, Restore From Backup, Save Diagnostic Info (versions, file sizes, and counts; no note text), or Create New Library (the old library is kept in `Recovery/`).

## Privacy

- JAASNotes has no network access and no accounts. Everything stays on your Mac.
- Logs and diagnostics do not include note text, titles, or full file paths.
- Notes are not encrypted by the app. FileVault and your macOS account protect the disk.

## Known limitations

- A crash, force-quit, or power loss can lose edits typed in the last 0.5 seconds (2 seconds during continuous typing), because autosave runs after that delay.
- Save failures are tested with injected failures, not with a real full disk.
- Recovery libraries in `Recovery/` are not removed automatically.
- Stage 1 is plain text only. Formatting, checklists, and attachments arrive in later stages.

## Documentation

- `AGENTS.md`: the implementation plan and the ordered checklist.
- `docs/decisions.md`: design decisions and approved changes.
- `docs/progress.md`: evidence for each substage and what remains.
- `docs/storage.md` and `docs/testing.md`: planned; not written yet.
