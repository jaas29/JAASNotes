# Testing

## Commands

Unit and integration (disk-backed SQLite in temporary folders):

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-<n>.xcresult -only-testing:JAASNotesTests test
```

UI (temporary library per test, selected by `JAASNOTES_TEST_LIBRARY_NAME`; debug builds only):

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/JAASNotes-ui-<n>.xcresult -only-testing:JAASNotesUITests test
```

Use a new result-bundle path on every run.

## Failure injection

- `FaultyNoteStore` (tests): fails updates or structural writes on demand; holds a named search query until released; pauses an update.
- `JAASNOTES_TEST_FAIL_SAVES=1` (debug UI runs): every write fails.
- `LibraryRestoreService.InterruptionPoint` (tests): stops a restore after moving the library aside or after installing the backup, without rollback, as a crash would.

## Stage 1 matrix status (see `docs/progress.md`)

| # | Scenario | Status |
| --- | --- | --- |
| 1 | Folders, moves, search, counts | Covered by unit, integration, and UI tests |
| 2 | Type, switch, close, quit, relaunch | UI: Cmd-S and Cmd-Q relaunch; window close not automated |
| 3 | Delete, quit, relaunch, restore; no purge | `TrashUITests`, `TrashRepositoryTests` |
| 4 | Old save finishing after newer edit | `AutosaveTests` with a paused store |
| 5 | Injected save failure, retry, recovery copy, canceled quit | Unit (`AutosaveTests`: retry without duplicates, recovery copy verified) and UI (canceled quit). The Retry button and save panel are exercised by the owner's manual pass |
| 6 | Force kill after a confirmed save and with unsaved text | `ForceQuitUITests` (SIGKILL after save); `PendingSaveKillUITests` (kill with unsaved text: library opens and the saved note remains) |
| 7 | Backup, modify, restore; interruption | `BackupRestoreTests`: restore interruption, fresh restore, and a snapshot interrupted at the publish step (no partial package, library intact) |
| 8 | Corrupt and future-schema fixtures | Corrupt, foreign-file, and other-model-hash tests pass (`testStoreWrittenByAnotherModelVersionIsRefused` rewrites a real store's model hashes) |
| 9 | Menus, keyboard, VoiceOver, appearance, long text, IME | Keyboard shortcuts tested; VoiceOver and the rest need a manual run |

## Manual checks (owner's Mac, macOS 26.6.2, M3 Pro)

The owner ran the VoiceOver walkthrough and the keyboard-only pass on this machine. Recorded as passed.

Still not run by anyone:


- VoiceOver walkthrough of create, edit, move, delete, restore, search, backups, and recovery.
- Keyboard-only pass with Tab order across sidebar, list, title, and body.
- Light and dark appearance, large Dynamic Type, long titles, and Japanese IME composition in title and body.
- A real full-disk or read-only-folder save failure.
