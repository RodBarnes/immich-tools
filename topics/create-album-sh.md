# `create-album.sh` — Recreate a Google Photos Album in Immich

## State

Test plan executed end-to-end and complete (2026-08-28) against real test
zips and Rod's own Immich account. Tests 1–9 passed; test 10 (cross-account
scoping regression check) explicitly waived — already verified previously,
not new ground. Two real bugs found and fixed during testing (see Design →
Fixed bugs below, commit `1150215`). **Script considered ready for real
use.**

Loose end: a stray test album literally named `-o` (created during the
test-5 failure, before the bug was understood) should be deleted manually
from the Immich UI if not already done.

**Open, not-yet-built idea:** a full workflow for recreating *all* Google
Photos albums in Immich (both accounts) — see Design → Proposed album-
recreation workflow below. Not started.

## Design

Solves a narrower, later-arising need than the main import pipeline:
recreating album structure in Immich that Google's Takeout export doesn't
preserve when downloaded by year rather than by album.

### Interface

`create-album.sh [-o|--override] <zip_file> <album_name>`.

- **`-o`/`--override` must precede the zip path** — the flag is only
  checked against `$1` before the two positional args are consumed;
  passing it after `<zip_file>` silently shifts it into the `album_name`
  slot instead of erroring. Confirmed during testing 2026-08-28 (Test 5:
  `create-album.sh data/test.zip -o "Test album 1"` created a bogus album
  literally named `-o`). Documented as a usage constraint, not hardened in
  the script itself.

### Filename extraction

Reads directly from the zip's directory listing (`unzip -Z1`), no
extraction needed. Filters to photo *and* video extensions (Google Photos
albums routinely include both, plus Motion Photo JPG+MP4 pairs) and
excludes Takeout's `.json` sidecar files.

**Fixed bug (2026-08-28):** filename extraction must not invoke `basename`
via `xargs -n1` — that splits on whitespace, so any filename containing a
space (common in this archive, e.g. `North Rim Grand Canyon.jpg`)
fragments into multiple bogus single-word "filenames." This caused Test 7
(zero-resolved case) to crash with `python3: Argument list too long` — one
bogus fragment broad-matched a large number of assets via
`/search/metadata`, and the resulting huge response, passed to `python3`
via an environment variable (`RESP="$response"`), exceeded `ARG_MAX`,
silently dropping that entry from all result buckets (no error, since the
script has no `set -e`). Fixed: extraction now uses a `while IFS= read -r`
loop with `${entry##*/}`, treating each `unzip -Z1` line as one unit; all
API responses are now piped to `python3` via stdin (`<<<"$response"`)
instead of an environment variable.

### Matching

One `POST /api/search/metadata` call per filename (`originalFileName`
filter — no batch-lookup support in the API, and this field is deprecated
as of Immich v3.2.0, a future maintenance point). Confirmed via a
deliberate cross-account test (same filename uploaded to both Rod's and
Karen's accounts) that this search is implicitly scoped to the
authenticated API key's own account — no explicit user filter needed.

- Exactly one match → resolved.
- Zero matches → logged to `*-not-found.txt`, not an error. Possible
  causes, none distinguishable by the script: genuinely never imported
  (e.g. deliberately moved to Nextcloud per policy), removed by Immich's
  own Duplicate Detection with a surviving copy under a different
  filename, or a Google Takeout duplicate-suffix (`(1)`, `(2)`) that
  doesn't match what's stored in Immich.
- Multiple matches → logged to `*-needs-review.txt`, never auto-picked.
- Log files are timestamped and album-named, never overwritten between
  runs.

### Album creation

`POST /api/albums` accepts `assetIds` directly, so a new album is created
and populated in one call. An existing album (same exact name) requires
`-o`/`--override` to add to it via `PUT /api/albums/{id}/assets`; without
the flag, the script reports the collision and exits without changes.
Multiple existing albums sharing the name is treated as an error requiring
manual resolution, never guessed.

### No `report`/`update` split

Unlike `exif-photos.sh`, the operation is non-destructive and trivially
reversible (delete the album if wrong), and the intended workflow already
includes manual visual review in the Immich UI before deleting anything
from Google Photos — a separate dry-run mode would just duplicate that
review a step earlier.

### Credential/instance-URL handling

Same `.env`-next-to-script pattern as `import.sh` (see
`topics/import-sh.md`). Defaults to the internal LAN address
(`http://192.168.0.19:2283/api`) rather than the external
`https://photos.advappsw.com` — intentional, since this never touches
Caddy/Cloudflare's TLS termination at all, so there's no protocol-mismatch
risk the way there was for the mobile apps (see
`topics/immich-server-upgrade.md`).

### Proposed album-recreation workflow (2026-08-25, not yet built/tested)

Replaces the current fully-manual per-photo workflow (open album in Google
Photos, copy filename, search/find/add in Immich UI, repeat):

1. Do a **separate Google Takeout export scoped to one specific album at a
   time** (Takeout supports selecting individual albums, unlike the
   original by-year export) — yields a folder per album containing exactly
   that album's files; the filename list is then just a directory listing.
2. Script: for each filename, query Immich's search API filtered by
   `originalFileName` to resolve it to an asset `id`.
3. Script: create the target album (if it doesn't exist) via `POST
   /api/albums`, then add all resolved asset IDs in one call via `PUT
   /api/albums/{id}/assets`.

**Not yet verified:** the exact search/add-to-album endpoint names,
params, and request/response shapes above are from general Immich API
knowledge, not confirmed against this instance's own Swagger docs
(`https://photos.advappsw.com/api/docs`) — check before implementing. Also
undecided: how to handle a filename search returning zero or multiple
matches (should be flagged for manual review, not guessed).
