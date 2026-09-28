# EXIF-Prep Pipeline (`exif-classify.sh` / `exif-photos.sh` / `find-duplicates.sh`)

## State

Done/stable — functionally finished for stated scope, in active use for
photos coming from `bard`. No open work on the tools themselves; remaining
work is applying them to specific folders (see `topics/family-folder-import.md`).

Confirmed via a full run against the already-migrated Google Photos
collection:
```
Files processed (photo types in YYYY/MM): 8868
Already had DateTimeOriginal            : 8101
Missing DateTimeOriginal                : 767
Skipped (outside YYYY/MM structure)     : 7858
Skipped (unsupported file type)         : 807
```

## Design

### Origin and scope

These tools process photos on `bard` (a NAS) — older photos with no EXIF
data, many of which have filenames that encode a usable date
(camera/scanner sequential names, phone timestamp names, etc.). Goal:
derive `DateTimeOriginal` and a `Description` so photos can be imported
into Immich correctly. Scope is bounded to this EXIF-preparation step, not
the broader import/Nextcloud workflow.

`exif-classify.sh` is not an end in itself — it's a diagnostic tool to
validate the filename-classification logic before trusting
`exif-photos.sh` to act on it.

### `find-duplicates.sh`

`find-duplicates.sh report|dedup <target_dir> [search_root]` — for each
file in `target_dir`, searches `search_root` (default `staging/bard`) for
other files with the *same filename*, then confirms true duplicates via
`sha256sum`. `report` lists `UNIQUE` / `DUPLICATE` / `NAME COLLISION` (same
name, different content — needs manual review, never auto-deleted, logs
`Conflict: <full path>`); `dedup` also deletes confirmed duplicates found
in `target_dir`. Run this first on folders suspected of holding redundant
copies (e.g. `USB/`) before the EXIF pipeline.

**Fixed bug (bash 5.2.37):** `read -r -d ''` clears its variable on the
final EOF call, which made `Conflict: $match` always print blank — see
`topics/immich-internals.md` for the general gotcha and fix.

### Classification design (`exif-classify.sh`)

Filenames (within a `YYYY/MM` structure) are classified in priority order,
most-confident pattern first: DATE-LIKE → CAMERA-PREFIX → CAMERA-SERIAL →
DESCRIPTIVE (catch-all). Order matters — e.g. `NNN_NNNN` (Olympus/Fuji)
must be checked before the broader `NNN_NNA` pattern, or the more specific
match never fires. Read-only; classifies every filename and tallies
non-photo videos and skip reasons separately, to sanity-check pattern logic
and audit directory-structure issues before trusting the update pass.

**Key constraint:** complex regexes with character classes or alternation
must be stored in a variable before use in `[[ =~ ]]` — inline complex
patterns fail silently in bash (see `topics/immich-internals.md`).

### Date derivation design (`exif-photos.sh`)

1. Parse from filename (`YYYYMMDD_HHMMSS`, `MMDDYYHHMM`, or `YYYYMMDD`
   anywhere in the name).
2. Fall back to `YYYY/MM` from the directory path, defaulting to day 01,
   00:00:00.
3. Lowest confidence: a standalone 4-digit year in the filename, logged as
   `filename-year-only`, defaults to Jan 1.
4. If none of these yield a date, the file is left **completely
   untouched** and logged `NEEDS REVIEW [no date source]` — no date is
   ever fabricated, and no description is written for a file with no date
   source either.

**`--time` / `--tz` options (added 2026-09-27):** without them, date-only
sources (`YYYYMMDD` name, `YYYY/MM` dir, year-only) are written as
`00:00:00` with no offset tag, which Immich treats as midnight UTC.
- `--time HH:MM[:SS]` replaces that `00:00:00` only for sources that have
  no time of their own; `YYYYMMDD_HHMMSS`/`MMDDYYHHMM` names keep their
  parsed time.
- `--tz` takes a fixed `±HH:MM` or an IANA zone name (e.g.
  `America/Boise`). A zone name is resolved per file against that file's
  date+time, so DST is applied. Written as `OffsetTimeOriginal`,
  `OffsetTimeDigitized`, `OffsetTime`, only on files whose date this
  script writes. Files with an existing `DateTimeOriginal` are untouched.
- Options go before the mode:
  `exif-photos.sh --tz America/Boise --time 12:00 report <dir>`.
- Why `--tz` is needed even for photos that will later get a location
  (confirmed by Rod's tests, 2026-09-27):
  - With **no** offset in the file, adding a location in Immich sets the
    timezone from the location but keeps the UTC moment fixed. Example:
    `1998:06:02 00:00:00` (no offset) showed as midnight UTC. After the
    location was added it became 5pm -07:00 on **June 1**, so the date
    moved back a day.
  - With an offset **already** in the file (written by `--tz` or directly
    with exiftool), adding a location changes neither the time nor the
    timezone.
- Tested end to end 2026-09-27: `--tz -07:00 --time 15:00 update` on an
  undated file under `YYYY/MM` → `import.sh` → location added in Immich;
  the date, time and offset were all unchanged.

Applies uniformly whether a file has no EXIF at all or has EXIF but is
missing `DateTimeOriginal` specifically. The script never uses a file's
own filesystem timestamp as a date source (that's a separate, Immich-side
display fallback only — see `topics/immich-internals.md`).

### Description derivation design

A filename alone can't reliably signal "descriptive vs. camera-generated,"
so:
1. Check the immediate subdirectory beneath `YYYY/MM` — if descriptive,
   use it.
2. Check the filename (minus extension) — if descriptive, use it.
3. If both are descriptive, combine as `"SubDir - Filename"`.
4. If neither is descriptive, leave blank rather than guessing.

Written to both `ImageDescription` and `XMP-dc:Description` (mirrors
Immich's read priority). Applies to any file missing a description, not
just files also missing a date. Files with an existing description are
never overwritten.

### `report`/`update` summary semantics (business rule — easy to misread)

- `Missing DateTimeOriginal: 0` means **genuine pre-existing EXIF was
  found** on the file itself. The fallback chain only executes when real
  EXIF is absent, so a file can never show as "not missing" purely because
  a fallback succeeded.
- `NEEDS REVIEW [no date source]` means every fallback failed — file left
  completely untouched, not even the description.
- The summary can undercount: files needing *only* a description (date
  already present/resolved) were originally logged per-file (`MISSING
  [desc] ...`) but not tallied in any summary bucket. Fixed 2026-08-08 by
  adding a `Needs description added` counter.
- `report` mode shows what an `update` run *would* derive (date + source,
  description), not just a bare `MISSING` flag — results can be reviewed
  before committing to a write pass.
- Only `jpg`, `jpeg`, `png`, `tif` are treated as photos (`PHOTO_EXTS`);
  `.gif` and other extensions are tallied under "Skipped (unsupported file
  type)," same as videos. No documented rationale exists for excluding
  `.gif` specifically (GIF files carry no EXIF data at all, confirmed via
  the `exif` CLI tool), but `png` is included despite similarly
  limited/inconsistent native EXIF support — "lacks EXIF" isn't a fully
  consistent explanation for the list as written.

### Resolved edge cases

- `Grad060703A.jpg`-style `MMDDYY` names fall back correctly to the
  directory date when not explicitly parsed.
- `Day1`/`Day2` subdirectories under a "50-miler" trip: judged not worth a
  special classification rule — handled by one-off manual cleanup instead
  of adding pattern complexity for a single case.
- No built-in backup: `exiftool -overwrite_original` modifies files in
  place. A manual backup (iDrive) is taken before any `update` run against
  real data.
- **`YYYY`-without-`MM` directory structure — resolved, not by extending
  the tools.** Rather than teaching the tools to recognize non-`YYYY/MM`
  structures, the resolution was to import as-is and route anything with
  an unresolved date into a dedicated "Attention!" album in Immich for
  later manual review. The tools' scope remains bounded to `YYYY/MM`
  structures — a deliberate scope decision, not an outstanding gap.

### Batch processing pattern

The tools don't support scoping directly to a single year or month —
`BASE_DIR` must be a directory whose *contents* are `YYYY/MM/...`. Working
pattern: move whichever `YYYY/MM` directories were confirmed ready into a
`staging/bard/ready/` subfolder, then run classify → report → backup →
update against that subfolder only, repeating per batch.

**Gotcha:** `BASE_DIR` must not have a trailing slash — breaks the
relative-path stripping (`${file#$BASE_DIR/}`), causing every file to
silently fall into "skipped (structure)" with no error. Not fixed in the
tools — just avoid trailing slashes when invoking them.

`YYYY`-only directories (pre-2000) were manually reorganized into
`YYYY/MM` to fit the tools' assumption, the same approach later applied
piecemeal to some `bard` years before the "Attention!" album approach
superseded doing this for every remaining case.
