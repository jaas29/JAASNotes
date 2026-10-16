# Storage

## Layout

```text
Application Support/JAASNotes/          (sandbox container; tests use a temporary root)
  Library/Store.sqlite(-wal,-shm)       Core Data SQLite store (live library)
  Backups/<yyyy-MM-ddTHH-mm-ssZ>-<id8>/ manifest.json + Library/ copy (validated before publication)
  Recovery/                             libraries moved aside by restores or "Create New Library"
  Staging/                              temporary copies; restore-transaction.json while a restore runs
```

## Schema

- Current model: version 3 (`JAASNotes 3.xcdatamodel`, set in `.xccurrentversion`). Versions 1 and 2 are kept as prior models.
  - `LibraryMetadata`, `Folder`: unchanged since version 1.
  - `Note`: `isPinned` (version 2); `contentFormatVersion`, `richTextData`, `checklistData` (version 3).
- `contentFormatVersion` is 0 for plain-text notes and 1 for notes with a rich body. A rich note keeps its plain text in `bodyPlainText`, which search and previews read.
- `richTextData` is RTF, limited to 16 MiB and to text and formatting (no attachments). `checklistData` is a versioned JSON sidecar of items: stable UUID, checked state, and a UTF-16 paragraph range in the plain text. Both are ordinary attributes, not external binary storage, so a backup's copy of `Store.sqlite` contains them.
- Version 4 adds `Attachment` (metadata only) and `Note.attachments` (cascade delete). The bytes live in `Library/Attachments/<UUID>/payload`, never in the store. A row's `relativePath` is always `Attachments/<UUID>/payload`; `AttachmentService.isSafeRelativePath` refuses anything else.
- Upgrades run only from a known prior version (`LibraryMigrationService.priorModelNames`). A store that matches neither the current model nor a prior one is refused before any write.
- Upgrades do not convert notes to rich text. A note becomes rich on its first rich save.
- A store is only opened after its metadata matches the bundled model (`CoreDataStack.checkCompatibility`); a file without Core Data's `Z_METADATA` table is refused before any write.

## Snapshot procedure

1. Flush pending drafts.
2. Lock the library (operations wait) and close the store.
3. Copy `Store.sqlite` and any `-wal`/`-shm` into `Staging/<id>/Library/`.
4. Open the copy with migration disabled; read metadata, folder count, and note counts.
5. Checksum the copied files (SHA-256) after step 4, because opening a store can change `-shm`.
6. Write `manifest.json` and rename the package into `Backups/`. Only then prune automatic backups beyond 7.
7. Reopen the live store. A reopen failure shows the recovery screen.

## Restore procedure

1. Read the manifest. Refuse a newer format. Verify checksums of the backup.
2. Copy the backup into staging and validate that copy. Nothing live has changed yet.
3. Write the transaction marker with the planned paths.
4. Move the current `Library/` into `Recovery/restore-<id>/`.
5. Move the staged copy into `Library/`, then validate it.
6. Remove the marker and the staging folder.

If step 4–5 fails, the code rolls back. If the process dies, `recoverInterruptedRestore` runs on the next load:
- Library present and opens → keep it (restore completed or original kept).
- Library missing, previous present → put the previous back.
- Library invalid, previous present → put the previous back.
- Otherwise the marker is removed and the staged copy is discarded.

## Limits

- Snapshots copy a closed store; the library is unavailable for that short copy.
- `Recovery/` is never pruned automatically.
- Attachments: payloads are copied into `Library/Attachments/`, hashed (SHA-256), and size-limited to 100 MiB per file. Backups copy the folder and checksum every payload; validation refuses a backup whose payload is missing, the wrong size, or has a different checksum.
- Inline pictures and files in the text are still refused before a save, because RTF writing would otherwise drop them silently. Attachments are a separate tray, not inline.
- Archives are not part of the store yet (Stage 4).
- Rich text is stored in precomposed (NFC) form. RTF round trips do not keep decomposed sequences (for example `e` plus a combining acute), so a note's first rich save may change those sequences to their precomposed form. The text looks the same. Checklist ranges move with their paragraphs.
