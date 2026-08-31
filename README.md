# immich-tools — Photo Import Pipeline for Immich

Scripts for consolidating a photo archive from another source (a NAS,
Google Photos, etc.) into a self-hosted [Immich](https://immich.app/)
instance: deduplicating against what's already staged, filling in missing
EXIF metadata, uploading in batches, and recreating album structure that a
bulk export doesn't preserve.

This repo was formerly `exif-tools`, scoped only to the EXIF-preparation
step below. It was renamed and expanded once the tooling grew to cover the
rest of the import pipeline.

---

## Dependencies

- **bash** (4.0+) — uses `[[ =~ ]]` with ERE patterns stored in variables
- **exiftool** (`libimage-exiftool-perl`) — required by `exif-photos.sh`

```bash
sudo apt install libimage-exiftool-perl
```

- **Docker** — required by `import.sh`, which runs
  `ghcr.io/immich-app/immich-cli:latest`
- An Immich API key (Settings → API Keys in the Immich UI) — required by
  `import.sh` and `create-album.sh`. Both look for a `.env` file next to the
  script itself (`IMMICH_API_KEY=<key>`), falling back to an interactive
  prompt if not found.

---

## Tools

Tools used in pre-processing and importing photos/images into Immich:

### 1. `find-duplicates.sh` — remove files already present elsewhere

```bash
./find-duplicates.sh report|dedup <target_dir> [search_root]
```

For each file in `target_dir`, searches `search_root` (default
`staging/bard`) for other files with the same filename, then confirms true
duplicates via `sha256sum`. `report` lists `UNIQUE` / `DUPLICATE` / `NAME
COLLISION` (same name, different content — flagged for manual review,
never auto-deleted). `dedup` also deletes confirmed duplicates found in
`target_dir`.

### 2. `exif-classify.sh` — validate filename patterns (read-only)

```bash
./exif-classify.sh <base_dir> [logfile]
```

Classifies every photo filename into `DATE-LIKE`, `CAMERA-PREFIX`,
`CAMERA-SERIAL`, or `DESCRIPTIVE`. Makes no changes — it's a diagnostic
step to catch misclassified filenames before trusting `exif-photos.sh` to
act on the same pattern logic.

### 3. `exif-photos.sh` — audit/fill missing EXIF metadata

```bash
./exif-photos.sh report|update <base_dir> [logfile]
```

Fills in `DateTimeOriginal`/`CreateDate` and `ImageDescription`/
`XMP-dc:Description` for photos missing those fields, without altering
files that already have them. Date is derived, in order of confidence:
existing EXIF (untouched) → filename timestamp → `YYYY/MM` in the
directory path → a standalone 4-digit year in the filename. If none of
these resolve, the file is left completely untouched and logged `NEEDS
REVIEW` — no date is ever fabricated. `report` previews what `update`
would do; `update` writes changes via `exiftool -overwrite_original`.

### 4. `import.sh` — upload a batch into Immich

```bash
./import.sh <source_path> [album_name]
```

Thin wrapper around the Immich CLI Docker image (`upload --recursive`).
`source_path` must be **absolute** (a relative path is silently
misinterpreted by Docker's `-v` flag as a named volume). `album_name`
defaults to `basename "$source_path"` when omitted; passing one uploads
straight into that album (created if it doesn't exist) — useful for
batches that need per-photo manual date/location review after import.
Re-running with an already-imported batch reports everything as
"Skipped" rather than erroring.

### 5. `create-album.sh` — recreate a Google Photos album

```bash
./create-album.sh [-o|--override] <zip_file> <album_name>
```

Solves a gap left by bulk-by-year Google Takeout exports: album structure
isn't preserved. Given a Takeout zip scoped to one album, reads the
filename list directly from the zip's directory listing, resolves each
filename to an already-imported Immich asset via the search API, then
creates (or, with `-o`/`--override`, adds to) an album with those assets.
Filenames with zero or multiple matches are logged to review files rather
than guessed.

### 6. `exif-fix.sh` -- update EXIF data on file
```bash
./exif-fix.sh [-d|--datetime <datetime>] [-z|--tz <tz-offset>] [-g|--gps lat,lng] [-a|--alt altitude] <filename>
```

Allows directly updating the EXIF by manually supplying datetime, timezone offset, gps coordinates, and/or altitude.

---

## Notes

- `exif-classify.sh`/`exif-photos.sh` expect (but don't require) a
  `YYYY/MM` directory structure — used as a date/description fallback when
  present; files elsewhere in `base_dir` are still processed, just without
  that fallback source.
- Only `jpg`, `jpeg`, `png`, `tif` are treated as photos; other extensions
  (videos, `.gif`, etc.) are skipped and tallied separately.
- No built-in backup: `exiftool -overwrite_original` and
  `find-duplicates.sh dedup` modify/delete files in place. Take a backup
  before running either against real data.
- Both `exif-classify.sh` and `exif-photos.sh` write output to the
  terminal and a log file simultaneously via `tee`.
