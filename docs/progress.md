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
