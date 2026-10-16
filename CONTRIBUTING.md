# Contributing to JAASNotes

JAASNotes is a native macOS notes app. Your notes are the most important thing it handles, so changes are reviewed for data safety before features.

## Ground rules

- Read `AGENTS.md` (the plan and its checklist) and the latest entries in `docs/progress.md` and `docs/decisions.md` before changing storage, saving, backups, migrations, attachments, or archives.
- Never use real user data in tests, fixtures, screenshots, or demos. Use synthetic data in temporary folders.
- Never delete or overwrite a library as a "fix". Damaged data is moved aside (Recovery), not removed.
- Changes to the data model add a new model version. Released model versions are never edited in place.
- Substantial changes (storage engine, file format, deployment target, a new dependency, network use, retention) need a recorded decision in `docs/decisions.md` first.
- No network access and no third-party runtime dependencies.

## Setup

Full Xcode is required (Command Line Tools alone are not enough). Tested with Xcode 26.3 on macOS 26.

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
```

For a signed local run, select your own team in the target's Signing settings. Do not commit a team identifier.

## Verification

Before opening a change, run the unit and integration tests, and the UI tests when the change touches the interface:

```sh
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new-name>.xcresult -only-testing:JAASNotesTests test
xcodebuild -project JAASNotes.xcodeproj -scheme JAASNotes -destination 'platform=macOS' -derivedDataPath .build/DerivedData -resultBundlePath .build/TestResults/<new-name>.xcresult -only-testing:JAASNotesUITests test
```

Use a new result bundle path for each run. UI tests can fail at launch when another app's window overlaps the test window; rerun the failing test alone before treating it as a regression, and say so in the pull request.

For changes to saving, migration, backup, restore, or attachments, add a test that injects the failure (see `JAASNotesTests/Integration`). A passing compile does not prove recovery works.

Record the result (commands, environment, and any remaining risks) in `docs/progress.md`.

## Where to change things

- `JAASNotes/Domain`: snapshots, rules, and the store protocol.
- `JAASNotes/Persistence`: Core Data model, records, and the single writer (`LibraryRepository`).
- `JAASNotes/Services`: backups, restores, migrations, rich text, attachments, and archives.
- `JAASNotes/Features`: SwiftUI views and the `LibraryModel` that drives them.

Views do not write to the store or the file system directly.

## Style

Match the surrounding code. Comments explain why, especially around data safety. Errors shown to people never include note text, titles, or full file paths.
