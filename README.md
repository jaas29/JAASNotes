# JAASNotes

JAASNotes is an independent, native macOS notes app. It is in early development. This README describes what runs today, how to build it, and what is not finished.

## Status

- **Stage 1 (plain-text app) and Stage 2 (organization and recovery): complete** with the evidence in `docs/progress.md`.
- **Stage 3 (rich text and checklists): in progress.**
  - Done: formatted notes are stored (RTF, checklist sidecar, and search text), with validation and recovery copies for damaged formatting; bold, italic, underline, headings, and bulleted lists; checklists with accessible checkboxes that keep their identity through edits, Return, paste, and undo.
  - Not done: a manual VoiceOver and keyboard walkthrough of the new controls, and the Stage 3 regression gate (03-04). Automated tests pass; see `docs/progress.md`.
- **Not built yet:** attachments, import and export, and any archive format (Stage 4).

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

## Formatting and checklists

- New and existing notes are plain text until you format them. The first Format command on a note makes it formatted. Plain notes keep their plain-text storage.
- **Format menu:** Bold (Cmd-B), Italic (Cmd-I), Underline (Cmd-U), Heading 1–3 (Option-Cmd-1…3), Body Text (Option-Cmd-0), Bulleted List (Shift-Cmd-L), Checklist (Shift-Cmd-C), Check or Uncheck Item (Shift-Cmd-Return).
- A checklist item has a checkbox beside its line. Checked state and identity survive edits, splitting a line with Return, pasting, and undo.
- Pictures and files cannot be added yet. Formatting is saved in the library, not in the file system.
- A note whose formatting cannot be read opens read-only, showing its saved text, with **Make Recovery Copy**. Its original is never overwritten.

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
- Rich text is stored in precomposed (NFC) form. The first formatted save of a note can change combining sequences such as `e` plus an accent to a single character. The text looks the same.
- Checklist items are not supported in a paragraph that also has a bullet.
- Text with carriage returns or Unicode line-separator characters (U+2028, U+2029) is saved as line feeds. Checklist positions are kept in step, but the paste of such text has not been tested.
- Recovery copies from "Save Recovery Copy…" keep plain text only.
- Attachments are not supported; inline pictures and files are refused before a save.

## Documentation

- `AGENTS.md`: the implementation plan and the ordered checklist.
- `docs/decisions.md`: design decisions and approved changes.
- `docs/progress.md`: evidence for each substage and what remains.
- `docs/storage.md` and `docs/testing.md`: planned; not written yet.
