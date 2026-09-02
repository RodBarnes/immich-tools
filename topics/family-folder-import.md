# `Family/` Named-Folder Import Pass

## State

**Active — current focus.** All numeric `YYYY`/`YYYY/MM` "Year" folders
from `bard` are fully imported (2026-08-24); the three-tier sweep (real
EXIF → filename/directory-inferred → `NEEDS REVIEW`) is complete for that
numeric scope. Remaining work is scoped entirely to the `Family/` folder —
the named-folder pass, previously deferred, is now active.

**Current subfolder in progress:** `Family/Wedding - Phillip & Ashley/Photographer`
(wedding date confirmed 2014-12-06):
- Photos with no EXIF at all: dated via direct `exiftool` write (not the
  `exif-tools` pipeline — see `topics/exif-tools-pipeline.md`), e.g.
  `exiftool -overwrite_original -r "-DateTimeOriginal=2014:12:06 00:00:00"
  "-CreateDate=2014:12:06 00:00:00" <dir>`. `-overwrite_original` is
  intentional — originals remain on `bard`, so exiftool's automatic
  `_original` backup files are unnecessary on `boss`.
- Separately, some other photos in this folder (not yet fully scoped) have
  *existing* EXIF dates that are wrong — camera clock error, event was
  2002-06-29 but EXIF shows 2002-07-07. Same approach corrects these;
  still deciding per-batch whether to flatten to a fixed date or use a
  relative shift (`-DateTimeOriginal-=0:0:8 0:0:0`) to preserve
  intra-event time-of-day ordering, pending confirmation of whether the
  offset is consistent across the whole batch.
- The benign `Warning: [minor] Fixed incorrect URI for xmlns:MicrosoftPhoto`
  seen during this run is expected/harmless — a malformed XMP namespace URI
  in files with pre-existing Windows-written XMP metadata; exiftool
  auto-corrects it, no data loss.

*Next step:* finish EXIF dating for `Wedding - Phillip & Ashley/Photographer`
(confirm scope/consistency of the wrong-date batch above), then import,
then proceed to the rest of `Family/`.

### Named-folder status per folder

- `Andrew/` — **done.** Processed with `exif-photos.sh`, imported, removed
  from `staging/bard`.
- `USB/` — **dedup done, rest deferred.** `find-duplicates.sh dedup` was
  run to remove confirmed duplicates. Remaining non-duplicate files still
  need `exif-photos.sh` report/update + import — deferred to this pass per
  the 2026-08-08 scoping decision, not immediate work.
- `Family/` — **in progress**, current focus (see above); started with
  `Wedding - Phillip & Ashley/Photographer`.
- `Pictures/`, `ready/`, `Collections/` (remaining subfolders),
  `Deployment 2015-2016/`, the `YYYY/<event-name>/` folders (`Vacation`,
  `OR-ID-WY-MT`, `Andrew Mission`, `DC Trip`, `PNWGT A/B/C`, etc.), and any
  named subfolder nested within a numeric path — **not yet started**,
  deferred. Same workflow as `Andrew/`: check for duplicates first, then
  run `exif-photos.sh` (or the album-first-review workflow below for
  date-poor content), then import.
- `Collections/Navy Years/` — **done.** Imported directly into its own
  Immich album (`import.sh`, no `exif-tools` pre-pass); Rod completed
  reviewing each photo in the Immich UI and setting approximate
  date/location. Photos came from Picasa; an `Originals/` subfolder was
  found — resolved per the Picasa policy below (keep edited version,
  discard `Originals`) — not yet confirmed deleted from disk.

## Design

### Album-first-review workflow (established pattern)

For folders where dates can't be reliably inferred any other way: import
straight into a dedicated Immich album (`import.sh <path> <album_name>`),
then manually review/set approximate date+location per photo in the Immich
UI. Validated on `Collections/Navy Years/` (see State above). Preferred
over trying to extend the automated tooling to handle undatable folders.

### Policy: Picasa `Originals` subfolders

Confirmed (2026-07-23) that Picasa creates an `Originals` subfolder
whenever a photo was edited and saved, containing the pre-edit version;
the file of the same name in the parent folder is the edited version.
**Decision: trust past editing decisions and keep the edited (parent
folder) version, discard the `Originals` copy** wherever this pattern
appears — no per-photo review needed. Confirmed via a spot-check on one
pair (`Falls by park.jpg`): same dimensions, ~88% of pixels differed
beyond a 5% fuzz threshold (`compare -metric AE -fuzz 5%` — see
`topics/immich-internals.md` for why the fuzz threshold matters),
visually a sharpening/contrast edit.

### Policy: first-pass sweep scope (2026-08-08)

For the pass through `bard`, only strictly numeric `YYYY/MM` paths were in
scope; every named directory, wherever it occurs (including `USB/` and
named subfolders nested inside numeric paths), was deferred to this later
pass.

### Google Photos status (context, not part of `bard` per se)

Both Rod's and Karen's Google Photos have been fully downloaded
(`staging/google-rod`/`staging/google-karen`, preserving GPS — avoiding
the known Google Takeout problem of GPS being stripped into JSON
sidecars) and fully imported into Immich. Originals are still kept in the
Google Photos accounts until per-photo date/location discrepancies
surfaced during Immich review are resolved; only then will a side-by-side
comparison confirm nothing was missed before deleting Google Photos
originals. (For the separate accidental-import-into-wrong-account
incidents affecting Google Photos batches, see
`topics/karen-rod-misimport.md`.)
