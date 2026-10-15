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

