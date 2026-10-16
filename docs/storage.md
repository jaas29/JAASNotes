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

- Version 1 only (`LibraryMetadata`, `Folder`, `Note`). Field definitions are in `AGENTS.md` §5.
- Automatic migration is disabled. A store is only opened after its metadata matches the bundled model (`CoreDataStack.checkCompatibility`); a file without Core Data's `Z_METADATA` table is refused before any write.

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
- Attachments, rich text, and archives are not part of the store yet (Stages 3–4).
