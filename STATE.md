# Immich Migration — Project State

_Last updated: 2026-08-28_

## README.md rewrite (2026-08-28) — complete

`README.md` was still titled/scoped as `exif-tools` and documented only
`exif-classify.sh`/`exif-photos.sh`, with no mention of `import.sh`,
`create-album.sh`, or `find-duplicates.sh`, or the repo's actual scope
(import pipeline, not just EXIF prep). Rewritten to describe all five tools
in pipeline order (dedup → classify → EXIF fill → upload → album
recreation) with usage and purpose for each. Committed as `2b851d0`.

## Repo consolidation (2026-08-29) — complete

This repo was renamed from `exif-tools` to `immich-tools` (GitHub and
local), and merged with the separate Nextcloud-based `immich` project
(`~/Nextcloud/claude/immich`, not a git repo) once the tooling scope grew
beyond EXIF-prep alone (`import.sh`, `create-album.sh`). `DESIGN.md`/
`STATE.md`/reference docs were reconciled by hand (not a blind merge) —
exif-tools' stale `STATE.md` was retired, its `DESIGN.md` content (algorithm
design, the `YYYY`-without-`MM` gap — resolved via the "Attention!" album
approach, not a tooling change) was folded into this file's counterpart.
`immich.md`/`notes.md` were reconciled into one `immich.md` reference guide;
`PROCESS.md` was deleted (redundant with this file's Open Items). The old
`~/Nextcloud/claude/immich` directory is retired — this repo is now the
sole surviving location for all of this project's code and docs. Continue
future sessions from here (`~/src/mine/immich-tools`), not the old path.

## Goal

Consolidate all photos from multiple sources into a single self-hosted
Immich instance on `boss`, replacing Google Photos entirely:

- Rod's Google Photos (`rodlbarnes@gmail.com`)
- Karen's Google Photos (`karenhubbellbarnes@gmail.com`)
- ~120GB of photos on `bard` (NAS/file server, formerly named `media`,
  renamed to resolve a naming conflict)

## Infrastructure

| Host    | Role                                                              |
|---------|--------------------------------------------------------------------|
| boss    | Immich host (192.168.0.19, Debian 13). Also runs Nextcloud AIO, Home Assistant |
| mite    | Caddy reverse proxy + Pi-hole                                      |
| brawn   | Rod's workstation (script development)                             |
| bard    | NAS — source of ~120GB of photos being consolidated onto boss (formerly named `media`) |

- Immich internal: `http://192.168.0.19:2283`
- Immich external: `https://photos.advappsw.com` (Caddy → boss:2283, DNS-only Cloudflare)
- Docker Compose: `/opt/immich/docker-compose.yml`
- Upload location: `/mnt/data/immich/library`
- Staging area: **deleted (2026-08-29 or earlier)** — was `~/tmp/staging` on
  boss (symlink to `/mnt/data/staging`, subdirs `bard`, `rwgps`,
  `google-karen`, `google-rod`), removed once everything staged had been
  imported. No staging area currently exists; recreate if a new import batch
  is needed.
- Postgres DB: `/mnt/data/immich/postgres`, container `immich-postgres`, table `asset`
- Rod's Immich user UUID: `cf0d38b8-611f-483c-a889-38ec7029909d`
- Karen's Immich user UUID: `6c7abd53-aac9-43fa-a607-ac3f3e205d2d`
- Full container list: `immich-server`, `immich-postgres`, `immich-redis`,
  `immich-machine-learning`.
- DB credentials lookup (on boss): `sudo grep -E "^DB_USERNAME|^DB_DATABASE_NAME" /opt/immich/.env`

## Open Issue: "Imported" album shows 0 items (in progress, paused)

On 2026-07-27, Rod reported: a batch of ~undated photos imported 2026-06-20
(all landed on that date since they had no date metadata) was selected in the
Immich UI and added to a newly-created album called "Imported". The album now
shows 0 items, and the photos can't be found in the main timeline under
June 20 either.

**Ruled out so far:**
- Not a stale-UI-cache issue — hard refresh (Ctrl+Shift+R) made no difference.

**Diagnosis in progress — next step:** query the Immich API directly
(bypassing the UI) to see whether the server itself reports 0 assets for the
album, which would point to a DB/server-side issue rather than a UI bug:
```
curl -H "x-api-key: $KEY" https://photos.advappsw.com/api/albums
```
First attempt returned a 104-byte response that `jq '.[] | select(...)'`
couldn't index as an array (likely an error object, e.g. `$KEY` unset or
invalid, rather than the expected album list) — Rod was about to re-run
without the `jq` filter to see the raw response and confirm `$KEY` is set,
but paused the session before that came back. **No further progress on this
specific issue as of 2026-08-08** — still parked at this exact point.

**Planned diagnostic sequence once the API call succeeds:**
1. Get the album's `id` and `assetCount` per the server (`/api/albums`).
2. `GET /api/albums/<id>` and check `.assets | length` — confirms whether the
   DB itself has 0 linked assets (server-side problem) vs. a UI-only bug.
3. Search the main timeline/Trash for the June 20 photos by date or filename
   to determine whether the assets exist at all, independent of the album
   question.
4. Only after root cause is confirmed (UI bug / failed album-link write /
   assets trashed or missing / wrong-account association) decide on a fix —
   no changes have been made yet, this is still pure diagnosis.

Note: given the prior Karen/Rod cross-account mis-import incident (see Key
Technical Learnings below), a wrong-account association is a low-probability
but not-yet-ruled-out possibility worth checking if the above steps don't
explain it.

## Immich Server Upgrade (v2.7.5 → v3.1.0) — in progress, started 2026-08-26

Goal: upgrade boss's Immich server from v2.7.5 to v3.1.0. Staged into four
checkpointed steps rather than one direct jump, given a documented
unresolved data-loss report on the exact 2.7.5→3.0.0 path (GitHub issue
`immich-app/immich#29445` — user reported missing photos/videos, license
key, and recent user accounts after that exact upgrade, closed without a
confirmed root cause) and a required Postgres vector-extension migration
that's a prerequisite for reaching v3.0.0 at all.

**Sequence:**
1. **VectorChord migration (pgvecto.rs → VectorChord)** — **done, verified
   2026-08-26.**
2. **Fresh backup checkpoint** — **in progress.** Waiting on the existing
   nightly 02:00 scheduled DB dump (no manual "run now" trigger exists in
   this API version — confirmed via the server's own route-mapping log
   output: `DatabaseBackupController` only exposes `GET`/`DELETE`/
   `start-restore`/`upload`, no `POST` to trigger a new dump on demand).
   Deliberately not doing a one-off manual `pg_dump` instead — no urgency,
   and sticking to the established/trusted backup mechanism was the
   preferred call.
3. **Upgrade to v3.0.3** — not started. v3.1.0's own changelog lists v3.0.3
   as its minimum required prior version, so this is a required stepping
   stone, not optional.
4. **Upgrade to v3.1.0** — not started.

**Key facts confirmed this session:**
- **Version-history discrepancy resolved.** Earlier docs (`ipc-error-break.md`,
  `search-failure.md`, and this file's former "Stack (as of v3.1.0..."
  heading) had misread Immich's periodic update-checker log line
  (`[Microservices:VersionService] Found v3.1.0, released at 7/29/2026`) as
  the server's own running version. That log line is only the update
  checker reporting the latest available release — boss has been running
  v2.7.5 the entire time, confirmed both via the Admin UI version display
  and via `docker logs immich-server`. `CLAUDE.md`'s heading corrected to
  `## Stack (as of v2.7.5, confirmed 2026-08-26)`.
- Immich's Docker Compose default already uses VectorChord — boss's
  `docker-compose.yml` explicitly pinned the deprecated
  `tensorchord/pgvecto-rs:pg14-v0.2.0` image instead, so the migration was
  required, not skippable, before any upgrade past v3.0.0 (v3.0.0 drops
  pgvecto.rs support entirely).
- **VectorChord migration steps taken (2026-08-26):** edited
  `/opt/immich/docker-compose.yml` — swapped the `immich-postgres` image to
  `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, added
  `shm_size: 128mb`, removed the compose-level `healthcheck:` block (the new
  image ships its own — confirmed working, `immich-postgres` reaches
  `healthy` without it). `docker compose up -d` completed cleanly:
  `clip_index` (28,102 rows) and `face_index` (33,494 rows) reindexed in
  ~12 seconds, old `pgvecto.rs` extension dropped, migrations ran with **no
  schema drift detected**. User verified the UI (Admin panel + all user
  accounts) working normally afterward.
- **Migration survived a full host reboot** of boss (2026-08-26, pending
  kernel update applied) — all containers, including `immich-postgres` and
  `immich-server`, came back `healthy` on their own after ~4-5 minutes. This
  is a stronger validation than the initial `docker compose up -d` alone,
  since it confirms the migrated config is durable across a cold restart,
  not just a live container replace. (Nextcloud's web UI took an extra
  minute or two to become responsive after its containers reported
  `healthy` post-reboot — plausibly explained by Docker healthchecks only
  confirming a lightweight internal check, not full PHP/Apache warm-up,
  especially with every container on the host starting cold simultaneously;
  not confirmed via logs, and not investigated further since it resolved on
  its own and isn't part of the Immich upgrade.)
- The recurring `pgvecto.rs` IPC-hang bug documented in `ipc-error-break.md`
  has not reappeared since the migration (expected, since `pgvecto.rs` is no
  longer in use) — worth continued observation, not yet declared
  permanently resolved.
- **`immich-server`/`immich-machine-learning` images are pinned to the
  `:release` tag**, not `${IMMICH_VERSION}` — there is no `.env` variable
  controlling the app version. Steps 3 and 4 above will require directly
  editing those two image tags to explicit version pins (e.g. `:v3.0.3`,
  then `:v3.1.0`) rather than bumping an environment variable.
- A `docker-compose.yml` mirrored in this project directory had been
  confirmed byte-for-byte in sync with the live file on boss as of
  2026-08-26, just before the VectorChord edit. Rather than update it to
  match, the user **deleted it** (2026-08-26) — a stale local copy of a file
  that lives on boss is a standing risk of confusion (it caused exactly
  that during this session), and pasting in actual current contents when
  needed is preferred over keeping a copy that can silently drift.

**Step 2 (backup) and step 3 (v3.0.3) both completed and verified 2026-08-27.**
The 2026-08-27 nightly dump landed as
`immich-db-backup-20260827T020000-v2.7.5-pg14.19.sql.gz` — its Postgres
point-version tag changed from `pg14.17` (all prior dumps) to `pg14.19`,
independently confirming the scheduled backup ran successfully against the
migrated database. The v3.0.3 upgrade (image tags on `immich-server`/
`immich-machine-learning`, which are pinned to `:release` with no
`${IMMICH_VERSION}` variable — had to be edited to explicit `:v3.0.3` tags)
came up clean: 17 DB migrations succeeded (including
`MigrateAlbumOwnerIdToAlbumUser`, `DropDeviceIdAndDeviceAssetId`), no schema
drift, both accounts verified working in the UI.

**Side incident (2026-08-28, resolved, unrelated to the upgrade work):**
after the v3.0.3 upgrade, both mobile apps (which had been silently stuck on
the old v2.7.5 client for months, confirmed via the `session` table's
`appVersion`/`updatedAt` columns — an authoritative, more reliable source
than trying to reconstruct history from F-Droid) stopped backing up.
Updating the mobile apps to v3.1.0 didn't fix it. Investigation initially
suspected a client/server major-version mismatch (Immich's docs say mobile
should be upgraded before the server, and v2.7.5-mobile-against-v3.0.3-server
was briefly a real condition), and separately turned up two unrelated
pre-existing corrupted JPEGs (`20120310_141449.jpg`, `SAM_1001.jpg`, both
from mid-August, both in Rod's own library — flagged for later, not
blocking). The actual root cause, found via the mobile app's own local
log file: the server URL had been mistyped as `http://photos.advappsw.com`
instead of `https://` when re-entering credentials on both phones during
today's app update — causing connection resets mid-upload
(`ProtocolException: unexpected end of stream`). Not editable from
Settings once set; required a full logout/login with the corrected URL on
each phone. **Resolved 2026-08-28.** Nothing about the VectorChord
migration or v3.0.3 upgrade itself was implicated.

**Step 4 (v3.1.0) completed and verified 2026-08-28.** Same image-tag edit
pattern as step 3 (`:v3.0.3` → `:v3.1.0` on `immich-server` and
`immich-machine-learning`). `docker compose up -d` came up healthy; UI
confirmed on v3.1.0; mobile upload confirmed working (after the unrelated
`http://` URL fix above).

**Upgrade project (v2.7.5 → v3.1.0) is now fully complete.** All four
staged steps done and independently verified: VectorChord migration, fresh
backup checkpoint, v3.0.3, v3.1.0. `CLAUDE.md`'s "Stack" heading should be
updated to reflect v3.1.0 as the new baseline.

## Current Focus

All numeric `YYYY`/`YYYY/MM` **"Year" folders from `bard` are now fully
imported into Immich** (2026-08-24). The three-tier sweep described below
(real EXIF → filename/directory-inferred → `NEEDS REVIEW`) is complete for
the numeric scope.

**Remaining work is scoped entirely to the `Family/` folder** — the
named-folder pass, previously deferred, is now the active focus. First
subfolder underway: `Family/Wedding - Phillip & Ashley/Photographer`
(wedding date confirmed as **2014-12-06**):
- Photos with no EXIF at all: dated via direct `exiftool` write (not the
  `exif-tools` pipeline), e.g.
  `exiftool -overwrite_original -r "-DateTimeOriginal=2014:12:06 00:00:00"
  "-CreateDate=2014:12:06 00:00:00" <dir>`. `-overwrite_original` is
  intentional here — originals remain on `bard`, so exiftool's automatic
  `_original` backup files are unnecessary on `boss`.
- Separately, some other photos in this folder (not yet fully scoped) have
  *existing* EXIF dates that are wrong — camera clock error, event was
  2002-06-29 but EXIF shows 2002-07-07. Same `exiftool -overwrite_original`
  approach corrects these; still deciding per-batch whether to flatten to a
  fixed date or use a relative shift (`-DateTimeOriginal-=0:0:8 0:0:0`) to
  preserve intra-event time-of-day ordering, pending confirmation of
  whether the offset is consistent across the whole batch.
- The benign `Warning: [minor] Fixed incorrect URI for xmlns:MicrosoftPhoto`
  seen during this run is expected/harmless — a malformed XMP namespace URI
  in files with pre-existing Windows-written XMP metadata; exiftool
  auto-corrects it, no data loss.

*Next Step:* finish EXIF dating for `Wedding - Phillip & Ashley/Photographer`
(confirm scope/consistency of the wrong-date batch above), then import, then
proceed to the rest of `Family/`.

**Named-folder photos — status per folder:**
- `Andrew/` — **done.** Processed with `exif-photos.sh`, imported into
  Immich, and removed from `staging/bard`.
- `USB/` — **dedup done, rest deferred.** `find-duplicates.sh dedup` was run
  to remove confirmed duplicates (files also present elsewhere in
  `staging/bard`). Remaining non-duplicate files still need `exif-photos.sh`
  report/update + import — now explicitly deferred to the named-folder pass
  per the 2026-08-08 scoping decision, not immediate work.
- `Family/` — **in progress**, current focus (see Current Focus above);
  started with `Wedding - Phillip & Ashley/Photographer`.
- `Pictures/`, `ready/`, `Collections/` (remaining subfolders),
  `Deployment 2015-2016/`, the `YYYY/<event-name>/` folders, and any named
  subfolder nested within a numeric path — **not yet started**, deferred.
- `Collections/Navy Years/` — **done.** Imported directly into its own
  Immich album (`import.sh` with no `exif-tools` pre-pass); Rod has
  completed reviewing each photo in the Immich UI and setting approximate
  date/location. The `Navy Years` album now reflects the finished set. This
  workflow (album-first import + manual per-photo date/location review) is
  the preferred approach for folders where dates can't be reliably inferred
  any other way. Photos in this folder came from Picasa; a `Originals/`
  subfolder was found — see Policy Decisions for the resolution (keep
  edited version, discard `Originals`) — not yet confirmed deleted from
  disk.

**Karen/Rod mis-import correction — in progress:** a batch of bard photos
(two sub-batches, 1979–1985 and 1991–2007, both imported 2026-07-21) was
mistakenly imported into Karen's Immich account instead of Rod's. Note: no
`ts-backup` snapshot covers this — the working path `~/tmp` on `boss` is
excluded from `ts-backup` by default. This didn't matter in the end, since
`exif-tools` was run on the boss-side staged copy, not on the originals on
`bard`, so the source data on `bard` was never altered and needed no
restore. The 2554 mis-imported assets were identified precisely (by
filesystem `ctime` cross-referenced against `originalPath` in Postgres — see
Key Technical Learnings) and moved to trash in Karen's account via the
`DELETE /api/assets` API (not yet emptied).
- **Re-copy from `bard` to staging: done** (per Rod, 2026-08-08).
- **Count verification: in progress.** A `find <dir> -type f | wc -l`
  comparison between the staging copy and `bard` showed a ~500 file
  discrepancy. Likely explanation: content under `Collections/` (e.g.
  `Navy Years/`, already processed/imported separately) inflates one side's
  count. An adjusted command excluding it was provided —
  `find . -type f -not -path './Collections/*' | wc -l` (or
  `-not -path '*/Collections/*'` if `Collections` can appear at more than
  one depth) — run on both sides. **Result not yet confirmed back.**
- Remaining after counts are confirmed to match: re-run `exif-tools` on the
  fresh copy, `import.sh` into **Rod's** account, verify, then empty Karen's
  trash for these assets.

**Known harmless oddities (parked, 2026-08-08) — no action needed unless
they resurface:**
- Rod's Immich library (`/mnt/data/immich/library/library/cf0d38b8-.../`)
  has a directory literally named `198` (not `1980`) containing a single
  empty subdirectory `05`. Confirmed via direct Postgres query
  (`SELECT ... FROM asset WHERE "originalPath" LIKE '%198/05%'` → 0 rows)
  that **no current asset references this path** — it's a filesystem-only
  orphan with no live DB row, not something Immich still tracks. How it was
  originally created is unknown (not investigated further — would require
  checking `immich_server` container logs around the directory's `May 25
  18:33` timestamp). Decision: leave it; Rod will watch for recurrence when
  he next imports something dated 1980.
- Karen's Immich library root has a self-referential symlink — a symlink
  named with Karen's own user UUID
  (`6c7abd53-aac9-43fa-a607-ac3f3e205d2d`), pointing back to that same
  absolute path (i.e., the directory contains a symlink to itself), dated
  `Jul 22 08:11`. No explanation found or confirmed — not part of Immich's
  normal library layout as far as investigated, but not verified against
  this Immich version's source/logs either. Confirmed harmless (doesn't
  block anything). Decision: leave it, strange but inert.
- Two files found in Karen's `1980/08/` during this investigation
  (`Barnes3.jpg`, `Barnes8.jpg`, mtime `Jul 21 17:05`) are very likely part
  of the still-trashed (not yet purged) Karen/Rod mis-import batch above —
  the mtime matches that batch's 2026-07-21 import date, and Immich trash
  doesn't remove files from disk until emptied.

### Bard prep pipeline (exif-tools — completed, in active use)

1. `find-duplicates.sh report|dedup <target_dir> [search_root]` — for each
   file in `target_dir`, searches `search_root` (default `staging/bard`) for
   other files with the *same filename* (mirrors `find <search_root> -name
   <filename>`), then confirms true duplicates via `sha256sum`. `report`
   just lists `UNIQUE` / `DUPLICATE` / `NAME COLLISION` (same name, different
   content — needs manual review, never auto-deleted; the log line includes
   `Conflict: <full path>` to the colliding file); `dedup` also deletes
   confirmed duplicates found in `target_dir`, keeping the matching file
   elsewhere. Run this first on folders suspected of holding redundant
   copies (e.g. `USB/`) before running the EXIF pipeline on what's left.
2. `exif-classify.sh <base_dir>` — read-only pass; classifies every filename
   as `DATE-LIKE`, `CAMERA-PREFIX`, `CAMERA-SERIAL`, or `DESCRIPTIVE`, and
   tallies non-photo videos and skip reasons (grouped/bucketed, not just a
   raw count) separately. Used to sanity-check the pattern logic and to
   audit directory-structure issues before trusting the update pass.
3. `exif-photos.sh report|update <base_dir>` — a `YYYY/MM` directory
   structure is used **when present** (both as a date fallback and for the
   description label) but is **not required** — files anywhere under
   `base_dir` are processed. `report` previews exactly what `update` would
   do; no changes are made. `update` sets:
   - `DateTimeOriginal`/`CreateDate`, in order of preference: existing EXIF
     (left untouched) → filename timestamp → `YYYY/MM` anywhere in the
     directory path → a standalone 4-digit year in the filename (lowest
     confidence, logged as `filename-year-only`, defaults to Jan 1). If none
     of these yield a date, the file is left **completely untouched** and
     logged `NEEDS REVIEW [no date source]` — no date is ever fabricated,
     and no description is written for a file with no date source either.
     `Missing DateTimeOriginal: 0` in the summary means real embedded EXIF
     was found (see Current Focus, tier 1) — the script never uses the
     file's own filesystem timestamp as a date source (that's a separate,
     Immich-side fallback for display purposes only — see Key Technical
     Learnings).
   - `Description` (`ImageDescription` + `XMP-dc:Description`): descriptive
     subdirectory name (first path component after `YYYY/MM` if present,
     otherwise the file's first path component) combined with a descriptive
     filename, when either/both qualify (camera-generated and date-like
     names are excluded).
   - Summary now includes a `Needs description added` counter (added
     2026-08-08) — see Tools & Scripts. Only `jpg`, `jpeg`, `png`, `tif` are
     treated as photos (`PHOTO_EXTS`); `.gif` and other extensions are
     skipped and tallied under `Skipped (unsupported file type)`, same as
     videos. No documented rationale exists in the repo for excluding
     `.gif` specifically (confirmed empirically this session that GIF files
     carry no EXIF data at all, via the `exif` CLI tool erroring on a real
     `.gif` from `bard`) — but note `png` is included in `PHOTO_EXTS`
     despite similarly limited/inconsistent native EXIF support, so "lacks
     EXIF" isn't a fully consistent explanation for the list as written.
4. Import into Immich via the CLI batch process (below).

**Principle:** a pre-import iDrive backup is taken before any destructive
EXIF `update` run (and before any `find-duplicates.sh dedup` run).

## Google Photos Status

- Both accounts' Google Photos have already been **downloaded in full** to
  `staging/google-rod` and `staging/google-karen` on boss.
- Downloads preserve full EXIF, **including GPS** — confirmed this avoids the
  known Google Takeout problem where GPS coordinates get stripped from image
  EXIF and moved into companion JSON sidecar files. Multiple photos can be
  downloaded per batch (year-based bulk selection in the web UI, ZIP export).
- **Both Rod's and Karen's Google Photos have been fully imported into
  Immich.** The originals still exist in the Google Photos accounts —
  they're being kept until per-photo date/location discrepancies surfaced
  during review in Immich are resolved. Once that cleanup is done, a
  side-by-side comparison against Google Photos will confirm nothing was
  missed before the originals are deleted from Google Photos.
- **Karen's Google Photos:** an earlier batch (~3,258 assets) was
  accidentally imported into Rod's account on 2026-06-15; identified via a
  direct Postgres query (`createdAt` on `asset`, since the API only filters
  by EXIF date) and removed via the Immich `DELETE /api/assets` API (moved to
  trash, not yet emptied). Karen's photos were then re-downloaded and
  imported using her own API key and a separate import script. Trash
  emptying is deferred until this is confirmed fully resolved.

## Import Mechanics (established)

- CLI image: `ghcr.io/immich-app/immich-cli:latest`, invoked via `import.sh`:
  mounts a local batch directory read-only into the container and runs
  `upload --recursive`.
- Workflow per batch: `cp -r staging/<source>/<YYYY> ~/tmp/immich/`, run
  `import.sh`, verify in the Immich UI, clear `~/tmp/immich/*`, repeat.
- Flattening subdirectory structure when copying into the import area is
  fine — Immich derives dates from EXIF, not from directory layout, and the
  CLI walks recursively regardless of depth.
- API keys are per-user (Settings → API Keys) — not the same as the
  `.env` `SECRET_KEY`/`IMMICH_SECRET`, which is for internal service-to-service
  communication only.
- Re-running an import with an already-imported batch reports everything as
  "Skipped" rather than erroring.
- `import.sh <source_path> [album_name]` — `source_path` must be
  **absolute** (see Key Technical Learnings for the Docker `-v` relative-path
  pitfall this caused on 2026-08-08). `album_name` defaults to
  `basename "$source_path"` when omitted. The Immich CLI's `--album-name`
  flag creates the album if it doesn't exist and adds all uploaded assets to
  it — this enables importing a batch straight into a review album (see
  `Collections/Navy Years/` above) instead of having to locate photos in
  Immich after the fact.
- **API key handling (redesigned 2026-08-08):** `import.sh` looks for a
  `.env` file in the *same directory as the script itself*
  (`$(dirname "$0")/.env`, not the current working directory) containing
  `IMMICH_API_KEY=<key>`. If found, it's used directly with no prompt. If
  `.env` doesn't exist or the variable isn't set, falls back to the original
  interactive `read -s` prompt. This `.env` is unrelated to the one at
  `/opt/immich/` (Immich's own `SECRET_KEY`/`IMMICH_SECRET` for internal
  service-to-service use). Recommended: `chmod 600 .env` once created, since
  it holds a live credential in plaintext.
- Images that are not tied to a specific memory/event (art, web images,
  reference collections) are moved to Nextcloud Photos instead of staying in
  Immich — moved via the Nemo/WebDAV+SSH windows, then deleted from Immich
  after confirming the copy.

## Open Items / On the Horizon

- **Immediate next step:** continue the `Family/` named-folder pass (see
  Current Focus) — currently `Wedding - Phillip & Ashley/Photographer` EXIF
  dating/correction, then import, then the rest of `Family/`.
- **Finish Karen/Rod mis-import correction:** re-copy from `bard` is done;
  confirm the staging-vs-`bard` file count matches (Collections-excluded
  comparison in progress); then re-run `exif-tools`, `import.sh` into Rod's
  account, verify, then empty Karen's trash for these assets.
- **Named-folder pass (active, numeric sweep is done):** `Family/` in
  progress; `USB/` (dedup already done, needs `exif-photos.sh` report/update
  + import), `Pictures/`, `ready/`, remaining `Collections/` subfolders,
  `Deployment 2015-2016/`, and the `YYYY/<event-name>/` folders (`Vacation`,
  `OR-ID-WY-MT`, `Andrew Mission`, `DC Trip`, `PNWGT A/B/C`, etc.) still
  queued — same workflow as `Andrew/`: check for duplicates first, then run
  the `exif-photos.sh` pipeline (or the album-first-review workflow for
  date-poor content), then import.
- **Determine best approach for establishing albums from Google Photos for
  both Karen's and Rod's accounts in Immich** — not yet started. Google
  Photos albums aren't preserved automatically by the bulk-download/import
  workflow used so far (see Google Photos Status below), since the original
  bulk download was done by year, not by album.

  **Proposed approach (2026-08-25, not yet built/tested):** replaces the
  current fully-manual per-photo workflow (open album in Google Photos,
  copy filename, search/find/add in Immich UI, repeat).
  1. Do a **separate Google Takeout export scoped to one specific album at a
     time** (Takeout supports selecting individual albums, unlike the
     original by-year export) — this yields a folder per album containing
     exactly that album's files; the filename list is then just a directory
     listing, no manual UI copy-paste needed.
  2. Script: for each filename in that list, query Immich's search API
     filtered by `originalFileName` to resolve it to an asset `id`.
  3. Script: create the target album (if it doesn't exist) via
     `POST /api/albums`, then add all resolved asset IDs in one call via
     `PUT /api/albums/{id}/assets`.

  **Not yet verified:** the exact search/add-to-album endpoint names,
  params, and request/response shapes above are from general Immich API
  knowledge, not confirmed against this instance's own Swagger docs
  (`https://photos.advappsw.com/api/docs`) — check that before implementing.
  Also undecided: how to handle a filename search returning zero or
  multiple matches (should be flagged for manual review, not guessed).
- Resolve remaining date/location discrepancies for imported Google Photos
  (both accounts) in Immich; then compare against the Google Photos
  originals to confirm completeness before deleting them from Google Photos;
  empty Immich trash once Karen's mis-import cleanup is confirmed resolved.
- Decide whether to merge all EXIF-era sources into a single area or keep
  them separate once everything is imported.
- Second-pass analysis phase planned after all EXIF-era photos are in Immich.
- Immich album sort order is hardcoded to "Newest first" — no fix expected
  near-term (tracked upstream as GitHub discussion #1689); Nextcloud is being
  used as an interim holding area for manually-ordered categorical albums.
- "Imported" album shows 0 items — diagnosis still paused, see Open Issue
  above.

## Policy Decisions

- **Picasa `Originals` subfolders:** confirmed (2026-07-23) that Picasa creates
  an `Originals` subfolder whenever a photo was edited and saved, containing
  the pre-edit version; the file of the same name in the parent folder is the
  edited version. Decision: trust past editing decisions and **keep the
  edited (parent folder) version, discard the `Originals` copy** wherever this
  pattern appears (e.g. `Collections/Navy Years/Originals/`) — no per-photo
  review needed. Confirmed via a spot-check on one pair (`Falls by
  park.jpg`): same dimensions, ~88% of pixels differed beyond a 5% fuzz
  threshold (`compare -metric AE -fuzz 5%`), visually a sharpening/contrast
  edit.
- **First-pass sweep scope (2026-08-08):** for the current pass through
  `bard`, only strictly numeric `YYYY/MM` paths are in scope; every named
  directory, wherever it occurs (including `USB/` and named subfolders
  nested inside numeric paths), is deferred to a later pass. See Current
  Focus / Open Items.

## Key Technical Learnings

- **`docker logs immich-server` shows only NestJS service/job logs** — no
  HTTP-level access logs by default.
- **Postgres query logs are NOT in `docker logs`**; they're written to files
  inside the `immich-postgres` container at
  `/var/lib/postgresql/data/log/postgresql-<date>.log`. Enable via
  `ALTER SYSTEM SET log_statement = 'all'; SELECT pg_reload_conf();` and
  revert to `'none'` after use.
- **Always pass `-P pager=off`** (or `--pset pager=off`) to `psql` run via
  `docker exec -it` — otherwise output goes into `less` inside the container
  tty and looks like a hang.
- **Immich does NOT retain history of soft-delete (trash)/restore events** —
  only permanent/hard deletes are audited (`asset_audit`,
  `album_asset_audit`, populated by AFTER DELETE triggers only). Once an
  asset is restored from trash, `asset.deletedAt` reverts to NULL and all
  trace is gone. A trash-related bug must be caught live (watch Trash view +
  tail logs) — no after-the-fact DB evidence exists.
- **Trashing an asset does not remove its row from the `album_asset` join
  table** — the asset stays linked, the album just displays as
  empty/thumbnail-less because trashed assets are filtered from the view.
- **Code-first debugging:** when script output doesn't match expectations,
  check the code for defects before assuming user error.
- **API vs. DB filtering:** `GET /api/assets` filters by photo EXIF date, not
  upload time — direct Postgres queries against `asset.createdAt` are needed
  to filter by when something was actually uploaded.
- **Bash regex:** complex `[[ =~ ]]` patterns with character classes or
  alternation must be stored in a variable first, or they fail silently.
- **Cloudflare must be DNS-only** for `photos.advappsw.com` /
  `cloud.advappsw.com` — proxied mode double-terminates TLS and imposes
  upload size limits incompatible with Immich/Nextcloud.
- **Caddy + symlinked Caddyfile:** Docker binds to the inode at container
  creation; if the Caddyfile becomes a symlink afterward, the container keeps
  the stale inode and needs recreation, not just a reload.
- **EXIF GPS removal** isn't possible from the Immich UI — requires exiftool
  on the original file.
- **Verification** relies on the importer's own summary output and
  re-running to confirm duplicates — Immich's on-disk library layout is
  opaque and not useful for count-based verification, **except** for
  confirming whether a specific on-disk path is orphaned: querying Postgres
  for `asset."originalPath"` matching that path (0 rows = orphan, no live
  asset references it) is a reliable, confirmed way to check (used
  2026-08-08 to confirm Rod's stray `198/05` directory is harmless).
- **Identifying a mis-imported batch by `createdAt` time window is
  unreliable** if the target account has other activity in the same window
  (e.g., mobile app background auto-backup uploading the owner's own recent
  photos coincidentally during the same period) — this pulled in unrelated
  rows and, separately, missed part of the actual batch (whose sub-batches
  were imported at different times than assumed). The reliable method:
  enumerate the exact files by filesystem `ctime` (see next point), then
  join against `asset.originalPath` in Postgres — this ties the DB row
  directly to the exact on-disk file rather than inferring from timestamps.
- **`find -newermt` compares mtime, not ctime.** `exiftool` (used by
  `exif-tools`) preserves a file's original modification time by default, so
  files processed today can still show an old mtime — `-newermt` will miss
  them. Use `-newerct` to compare ctime (inode change time), which reflects
  when the file was actually written to the current filesystem, unaffected
  by preserved EXIF/mtime metadata.
- **`\copy` in psql is a client meta-command**, not SQL — it must run inside
  an interactive/scripted `psql` session (`-f script.sql`), not via `-c`.
  Also: `immich-postgres` only sees its own container filesystem, so files
  need `docker cp`'d in before `\copy FROM` can read them, and back out
  after `\copy ... TO` writes them.
- **`read -r -d ''` clears its variable on the final (EOF) call**, at least
  on bash 5.2.37 (confirmed on `boss`). A `while read -d '' match; do ...
  done < <(find ...)` loop leaves `$match` empty immediately after the loop
  ends, even though it held a value on the last successful iteration — this
  caused `find-duplicates.sh`'s `Conflict: $match` to always print blank.
  Fix: capture the value into a separate variable inside the loop body
  before it can be cleared, and reference that variable after the loop.
- **Docker `-v` bind mounts require an absolute host path.** A relative path
  is silently interpreted as a *named volume* instead. If the relative path
  contains a `/`, Docker rejects it with an "invalid characters for a local
  volume name" error. If the relative path is a single bare word with no
  `/` (e.g. `immich`), Docker does **not** error at all — it silently
  creates a fresh, empty named volume with that name and mounts it, so
  `import.sh` reports "No files found, exiting" even though the intended
  source directory exists and has files. Always pass an absolute path to
  `import.sh`.
- **ImageMagick `compare -metric AE` with no `-fuzz` threshold is not a
  useful similarity measure for two separately-saved JPEGs** — lossy
  recompression alone shifts nearly every pixel by 1+ out of 255, making AE
  read as "almost the entire image differs" even for visually identical
  files. Add `-fuzz N%` (5% worked well here) to ignore compression noise and
  get a meaningful count of pixels that actually changed.
- **Picasa's "date taken" fallback:** when a photo has no EXIF/IPTC date at
  all (confirmed via both Pillow and `exiftool` — genuinely absent, not
  hidden), Immich falls back to displaying the file's filesystem
  last-modified timestamp as the photo's date. Several bard photos edited in
  Picasa (`Software: Picasa 2.7` tag, no date fields) show dates like
  `12-01-2007` this way — not an Immich default/placeholder, an actual
  preserved mtime from years ago. This is an **Immich display fallback
  only** — confirmed 2026-08-08 that `exif-photos.sh` itself never uses a
  file's filesystem timestamp as a date source (its fallback chain stops at
  filename/directory/year-only; if all of those fail, the file is left
  untouched and flagged `NEEDS REVIEW`, nothing more).
- **Immich's on-disk library path directly maps to `asset.originalPath` in
  Postgres.** Confirmed 2026-08-08: querying
  `SELECT ... FROM asset WHERE "originalPath" LIKE '%<path fragment>%'`
  reliably tells you whether a given on-disk path under
  `/mnt/data/immich/library/library/<userId>/...` is a live, tracked asset
  or a filesystem-only orphan (0 rows).
- **`exiftool -TagsFromFile` restores metadata GIMP strips on export.**
  Confirmed 2026-08-15 on a red-eye-fixed photo (`IMAG0012.jpg` →
  `IMAG0012x.jpg`): GIMP's JPEG export produces a file with zero EXIF at
  all, not just a missing date (confirmed via `exiftool` directly, not a
  GUI properties panel). Fix: `exiftool -TagsFromFile <original.jpg>
  <edited.jpg>` copies the full tag set from the untouched original onto
  the edited file. Verified via `exiftool -s` diff against the original —
  `DateTimeOriginal`, `CreateDate`, `Make`, `CameraModelName`,
  `Orientation`, and `ImageSize` all matched afterward; the only remaining
  differences were harmless JPEG re-encoding artifacts from GIMP's export
  itself (`EncodingProcess`, `YCbCrSubSampling`) and EXIF-block structural
  differences (`ExifByteOrder`, `ThumbnailOffset`), not metadata loss.
  Applies to any Picasa/GIMP-edited photo in the `bard` set.

## Tools & Scripts

- `exif-classify.sh` — filename classifier (read-only), in `~/src/mine/exif-tools/` on brawn
- `exif-photos.sh` — EXIF audit (`report`) / patch (`update`) tool; works with
  or without a `YYYY/MM` structure. Summary now includes a `Needs
  description added` counter (added 2026-08-08) — previously, files needing
  only a description (date already fine) were logged per-file
  (`MISSING [desc]`) but not tallied in any summary bucket at all; this
  closed that gap.
- `find-duplicates.sh` — filename+sha256 duplicate finder (`report`) /
  remover (`dedup`)
- `import.sh` — Immich CLI Docker wrapper for batch uploads. Usage:
  `import.sh <source_path> [album_name]` (`source_path` must be absolute).
  Reads `IMMICH_API_KEY` from a `.env` file next to the script if present
  (added 2026-08-08); otherwise prompts interactively (`read -s`).
- `exiftool` — metadata utility, installed on `boss`/`brawn`
- `ffmpeg` — only installed on `bard` (Plex/media server); not present on
  `boss` or other servers
- `imagemagick` (`identify`, `compare`) — installed on `boss` this session
  for pixel-level comparison of Picasa edited-vs-original photo pairs; Rod
  may remove it once the `bard` photo project is complete
- Scripts are transferred to target servers via `scp`; naming convention:
  hyphens for executables, underscores for non-executables
