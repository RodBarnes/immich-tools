# Immich Migration — Design Notes

_Last updated: 2026-08-29_

Architecture and design decisions that are stable enough not to belong in
the chronological progress log (`STATE.md`). See `STATE.md` for current
status and open items.

## Repository structure

All scripts and design/status docs live in one repo (`immich-tools` on
GitHub, `~/src/mine/immich-tools` locally — formerly `exif-tools`, renamed
and merged with the separate Nextcloud-based `immich` project once the
scope grew beyond EXIF-only prep). Photo data itself (`staging/`, and any
`.env` holding a live Immich API key) never lives in this repo — it stays on
`boss` or wherever it's actively being worked, excluded via `.gitignore`.

## EXIF-prep tooling: `exif-classify.sh` / `exif-photos.sh`

### Origin and scope

These tools exist to process photos on `bard` (a NAS) — older photos with no
EXIF data, many of which have filenames that encode a usable date
(camera/scanner sequential names, phone timestamp names, etc.). The goal is
to derive `DateTimeOriginal` and a `Description` for those photos so they
can be imported into Immich correctly. Scope is bounded to this
EXIF-preparation step, not the broader import/Nextcloud workflow (see
`immich.md` for that).

`exif-classify.sh` is not an end in itself — it's a diagnostic tool to
validate the filename-classification logic before trusting `exif-photos.sh`
to act on it.

### Classification design

Filenames (within a `YYYY/MM` structure) are classified in priority order,
most-confident pattern first: DATE-LIKE → CAMERA-PREFIX → CAMERA-SERIAL →
DESCRIPTIVE (catch-all). Order matters — e.g. `NNN_NNNN` (Olympus/Fuji) must
be checked before the broader `NNN_NNA` pattern, or the more specific match
never fires.

**Key technical constraint:** complex regexes with character classes or
alternation must be stored in a variable before use in `[[ =~ ]]` — inline
complex patterns fail silently in bash. Standing rule for any future pattern
work in these scripts.

### Date derivation design

1. Parse from filename (`YYYYMMDD_HHMMSS`, `MMDDYYHHMM`, or `YYYYMMDD`
   anywhere in the name).
2. Fall back to `YYYY/MM` from the directory path, defaulting to day 01,
   00:00:00.

Applies uniformly whether a file has no EXIF at all or has EXIF but is
missing `DateTimeOriginal` specifically — both get the same derivation
treatment. No date is ever fabricated beyond this chain; if it fails
entirely, the file is left untouched (see `exif-photos.sh` report semantics
below).

### Description derivation design

A filename alone can't reliably signal "descriptive vs. camera-generated,"
so the agreed logic is:

1. Check the immediate subdirectory beneath `YYYY/MM` — if descriptive, use it.
2. Check the filename (minus extension) — if descriptive, use it.
3. If both are descriptive, combine as `"SubDir - Filename"`.
4. If neither is descriptive, leave blank rather than guessing.

Written to both `ImageDescription` and `XMP-dc:Description` (mirrors
Immich's read priority). Applies to any file missing a description, not
just files also missing a date. Files with an existing description are
never overwritten.

### `exif-photos.sh` report semantics (business rule)

The `report`/`update` summary counters have a specific meaning that matters
for triaging large batches — worth stating explicitly since it's easy to
misread:

- `Missing DateTimeOriginal: 0` for a file means **genuine pre-existing EXIF
  was found** on the file itself. The filename → directory → year-only
  fallback chain only executes when real EXIF is absent, so a file can
  never show as "not missing" purely because a fallback succeeded — either
  real EXIF exists, or the file is flagged as missing (and then further
  broken down into which fallback source, if any, resolved it).
- `NEEDS REVIEW [no date source]` means every fallback failed — the file is
  left **completely untouched** (no `exiftool` write at all, not even the
  description), by design.
- The summary can undercount: as originally written, files needing *only* a
  description (date already present or resolved) were logged per-file
  (`MISSING [desc] ...`) but not tallied in any summary bucket — `Files
  processed` would not equal the sum of the other visible counters. Fixed
  2026-08-08 by adding a `Needs description added` counter.
- `report` mode shows what an `update` run *would* derive (date + source,
  description), not just a bare `MISSING` flag — so results can be reviewed
  before committing to a write pass.

### Resolved edge cases

- `Grad060703A.jpg`-style `MMDDYY` names fall back correctly to the
  directory date when not explicitly parsed.
- `Day1`/`Day2` subdirectories under a "50-miler" trip were judged not worth
  a special classification rule — handled by one-off manual cleanup instead
  of adding pattern complexity for a single case.
- No built-in backup: `exiftool -overwrite_original` modifies files in
  place. A manual backup (iDrive) is taken before any `update` mode run
  against real data.
- **`YYYY`-without-`MM` directory structure (e.g. some `bard` years like
  1986, 1988, 2020 with no `MM` level; others like 2013/2014/2017 with
  descriptive event folders directly under `YYYY`) — resolved, not by
  extending the tools.** Rather than teaching `exif-classify.sh`/
  `exif-photos.sh` to recognize non-`YYYY/MM` structures, the practical
  resolution was to import as-is and route anything with an unresolved date
  into a dedicated "Attention!" album in Immich for later manual review —
  see `immich.md`. The tools' scope remains bounded to `YYYY/MM`
  structures; this is a deliberate scope decision, not an outstanding gap.

### Batch processing pattern

The tools don't support scoping directly to a single year or month —
`BASE_DIR` must be a directory whose *contents* are `YYYY/MM/...`
(scoping to `BASE_DIR/YYYY` breaks the structural match, since the
relative path from there is only `MM/...`). To process `bard`'s content in
sets, the working pattern was: move whichever `YYYY/MM` directories were
confirmed ready into a `staging/bard/ready/` subfolder, then run
classify → report → backup → update against that subfolder only, repeating
per batch.

**Gotcha:** `BASE_DIR` must not have a trailing slash. A trailing slash
(e.g. `staging/bard/ready/` instead of `staging/bard/ready`) breaks the
relative-path stripping (`${file#$BASE_DIR/}`), causing every file to
silently fall into "skipped (structure)" with no error. Not considered
worth fixing in the tools — just avoid trailing slashes when invoking them.

### Status

`exif-classify.sh` and `exif-photos.sh` are functionally finished for their
stated scope. Confirmed via a full run against the already-migrated Google
Photos collection:

```
Files processed (photo types in YYYY/MM): 8868
Already had DateTimeOriginal            : 8101
Missing DateTimeOriginal                : 767
Skipped (outside YYYY/MM structure)     : 7858
Skipped (unsupported file type)         : 807
```

`YYYY`-only directories (pre-2000) were manually reorganized into `YYYY/MM`
to fit the tools' directory assumption, the same approach later applied
piecemeal to some `bard` years before the "Attention!" album approach
superseded doing this for every remaining case. `Family/` and `USB/` flat
collections were explicitly deferred/out of scope for this tooling — see
`STATE.md` for their current status.

## `import.sh` — Immich CLI wrapper

Thin wrapper around `docker run ghcr.io/immich-app/immich-cli:latest upload`.

- **Interface:** `import.sh <source_path> [album_name]`. `source_path` must
  be **absolute** — Docker's `-v` bind-mount flag interprets any relative
  path as a *named volume* instead of a host path, with two distinct
  failure modes depending on the relative path's shape (see `STATE.md` →
  Key Technical Learnings for the full mechanism). There is no validation
  in the script for this — passing a relative path fails silently or with a
  misleading error, not a clear "must be absolute" message.
- **Album handling:** `album_name` defaults to `basename "$source_path"`
  when omitted. The Immich CLI's `--album-name` flag both creates the album
  if missing and adds every uploaded asset to it — this is relied on
  deliberately for folders where per-photo manual date/location review is
  needed (import straight into a review album, review in the Immich UI,
  rather than locating the photos after the fact). See `Collections/Navy
  Years/` in `STATE.md` for the validated example of this pattern.
- **Credential handling (redesigned 2026-08-08):** precedence order is
  `.env` file next to the script (`$(dirname "$0")/.env`, containing
  `IMMICH_API_KEY=<key>`) → interactive `read -s` prompt as fallback. The
  `.env` lookup is intentionally script-directory-relative, not
  cwd-relative, so behavior is consistent regardless of where the script is
  invoked from. This `.env` is a distinct file from `/opt/immich/.env`
  (Immich's own `SECRET_KEY`/`IMMICH_SECRET`, used for internal
  service-to-service auth only — unrelated to per-user API keys). Rejected
  alternative: passing the key as a CLI argument — works, but leaves the
  key in shell history and briefly visible in `ps` output; the `.env`
  approach avoids both.

## `create-album.sh` — recreate a Google Photos album in Immich

Solves a narrower, later-arising need: recreating album structure in Immich
that Google's Takeout export doesn't preserve when downloaded by year rather
than by album (see `STATE.md`).

- **Interface:** `create-album.sh [-o|--override] <zip_file> <album_name>`.
- **Filename extraction:** reads directly from the zip's directory listing
  (`unzip -Z1`), no extraction needed. Filters to photo *and* video
  extensions (Google Photos albums routinely include both, plus Motion
  Photo JPG+MP4 pairs) and excludes Takeout's `.json` sidecar files.
- **Matching:** one `POST /api/search/metadata` call per filename
  (`originalFileName` filter — no batch-lookup support in the API, and this
  field is deprecated as of Immich v3.2.0, a future maintenance point).
  Confirmed via a deliberate cross-account test (same filename uploaded to
  both Rod's and Karen's accounts) that this search is implicitly scoped to
  the authenticated API key's own account — no explicit user filter needed.
  - Exactly one match → resolved.
  - Zero matches → logged to a `*-not-found.txt` file, not treated as an
    error. Possible causes, none distinguishable by the script: genuinely
    never imported (e.g. deliberately moved to Nextcloud per policy),
    removed by Immich's own Duplicate Detection with a surviving copy under
    a different filename, or a Google Takeout duplicate-suffix (`(1)`,
    `(2)`) that doesn't match what's stored in Immich.
  - Multiple matches → logged to a `*-needs-review.txt` file, never
    auto-picked.
  - Log files are timestamped and album-named, never overwritten between
    runs.
- **Album creation:** `POST /api/albums` accepts `assetIds` directly, so a
  new album is created and populated in one call. An existing album (same
  exact name) requires `-o`/`--override` to add to it via
  `PUT /api/albums/{id}/assets`; without the flag, the script reports the
  collision and exits without changes. Multiple existing albums sharing the
  name is treated as an error requiring manual resolution, never guessed.
- **No `report`/`update` split** (unlike `exif-photos.sh`): the operation is
  non-destructive and trivially reversible (delete the album if wrong), and
  the intended workflow already includes a manual visual review in the
  Immich UI before deleting anything from Google Photos — a separate
  dry-run mode would just duplicate that review a step earlier.
- **Credential/instance-URL handling:** same `.env`-next-to-script pattern
  as `import.sh`. Defaults to the internal LAN address
  (`http://192.168.0.19:2283/api`) rather than the external
  `https://photos.advappsw.com` — intentional, since this never touches
  Caddy/Cloudflare's TLS termination at all, so there's no protocol-mismatch
  risk the way there was for the mobile apps (see `STATE.md`).
- **`-o`/`--override` must precede the zip path** — the flag is only checked
  against `$1` before the two positional args are consumed; passing it after
  `<zip_file>` silently shifts it into the `album_name` slot instead of
  erroring. Confirmed during testing 2026-08-28 (see `STATE.md`). Documented
  as a usage constraint, not yet hardened in the script itself.
- **Filename extraction must not invoke `basename` via `xargs -n1`** — that
  splits on whitespace, so any filename containing a space (a normal
  occurrence in this photo archive, e.g. `North Rim Grand Canyon.jpg`)
  fragments into multiple bogus single-word "filenames." Fixed 2026-08-28:
  extraction now uses a `while IFS= read -r` loop with `${entry##*/}`, which
  treats each `unzip -Z1` line as one unit.
- **API responses must be passed to `python3` via stdin, not an environment
  variable.** Passing a large response as `RESP="$response"` risks
  `execve`'s combined argv+envp size limit (`ARG_MAX`) — confirmed
  2026-08-28 when a bogus fragment produced by the `xargs` bug above (a
  short, generic word) apparently broad-matched many assets via
  `/search/metadata`, and the resulting response blew `ARG_MAX`, silently
  dropping that filename from all three result buckets (no error, since the
  script has no `set -e`). All three `python3` calls that consume an API
  response now read it from stdin (`<<<"$response"`) instead.

## Immich on-disk library layout

Immich stores uploaded assets under
`/mnt/data/immich/library/library/<userId>/<YYYY>/<MM>/<filename>`,
generated internally by Immich from each asset's resolved date — **not**
from the staging directory structure used during import (subdirectory
structure is flattened freely when copying into the import area; Immich
derives dates from EXIF, not from directory layout).

- **`asset.originalPath` in Postgres maps directly to this on-disk path.**
  Confirmed 2026-08-08: querying
  `SELECT ... FROM asset WHERE "originalPath" LIKE '%<fragment>%'` reliably
  tells you whether a given on-disk path is a live, DB-tracked asset or a
  filesystem-only orphan (0 rows). This is the general-purpose technique
  for reconciling what's on disk against what Immich actually tracks —
  used both for the Karen/Rod mis-import identification (see `STATE.md`)
  and for confirming stray/orphaned directories are harmless.
- **Display-only date fallback:** if an asset has no EXIF/IPTC date at all,
  Immich falls back to showing the file's filesystem last-modified
  timestamp as the photo's date in the UI. This is purely a display
  fallback inside Immich — it does not write anything back to the file, and
  it's unrelated to `exif-photos.sh`'s own (separate, stricter) fallback
  chain, which never uses filesystem timestamps as a date source.
