# Timezone Correction for Already-Imported Photos

_Started: 2026-09-01_

Spun out from `STATE.md` per the 2026-09-01 decision to keep individual
discussion topics in their own file rather than letting `STATE.md` grow
unwieldy — see `STATE.md`'s "Related Topic Docs" section.

## Goal

A large number of photos already imported into Immich have no timezone
recorded (`asset_exif.timeZone IS NULL`) because the source EXIF never had
one. Resolve this now that the photos are already in Immich, rather than
re-running the original `bard`/Google-Photos import pipeline.

## Confirmed mechanism (2026-09-01)

- Immich stores `dateTimeOriginal`/`modifyDate` (UTC, `timestamptz`) and
  `timeZone` (nullable `character varying`) on `asset_exif`. `asset.localDateTime`
  (`timestamptz`, not null) is a separate field Immich uses for timeline
  grouping/sorting/display — it's derived from EXIF + timezone at import
  time, not recomputed automatically by a DB-only edit.
- **Directly editing `asset_exif.timeZone` in Postgres was considered but not
  pursued** — risk of leaving `localDateTime` inconsistent with the new
  timezone, and no confirmation that a DB-only edit would survive any future
  metadata re-extraction (which reads from the file, not the DB).
- **Confirmed working approach instead:** edit the photo file directly in
  its live library path
  (`/mnt/data/immich/library/library/<userId>/<YYYY>/<MM>/<filename>`) with
  `exiftool`, writing `OffsetTimeOriginal`/`OffsetTime` tags, then trigger
  Immich's **per-asset "Refresh Metadata"** action (three-dot ⋮ menu on the
  asset's info panel in the web UI). Verified end-to-end 2026-09-01 on
  `100_0393+1.jpg` (Beartooth Pass, WY summit, dated 2017-07-24 → set to
  `-06:00` MDT) — the UI picked up and displayed the corrected timezone
  after the refresh.
- **The global Admin → Job Queues → "Extract Metadata" → "Missing" job does
  NOT do this** — confirmed by testing: it left the test photo's timezone
  unchanged. It appears to only process assets with no `asset_exif` row at
  all, not existing rows that are simply missing one field. No "reprocess
  all" option was available in this version's Jobs UI (only "Missing" and,
  separately, "Discover" for sidecar files).
- **`exiftool` gotcha:** some files (older camera JPEGs with malformed
  MakerNotes) refuse to write at all (`0 image files updated`) unless `-m`
  (ignore minor errors) is passed.
- **The per-asset "Refresh Metadata" UI button calls:**
  ```
  POST /api/assets/jobs
  Body: {"name": "refresh-metadata", "assetIds": ["<uuid>", ...]}
  ```
  Confirmed via browser dev tools Network tab capture (204 No Content on
  success). Takes an array, so many asset IDs can be batched into one call
  rather than one request per photo — this is the endpoint a batch script
  would call after writing offsets to the underlying files.

## Schema notes (v3.1.0, confirmed 2026-09-01)

- `asset_exif.timeZone` — nullable `character varying`. Target field for
  this whole effort.
- `asset.originalPath` — resolves an asset row to its on-disk library file
  path (same technique used previously for the Karen/Rod mis-import
  investigation — see `STATE.md` Key Technical Learnings).
- `asset.localDateTime` — `timestamptz`, not null; drives timeline
  grouping/sort/display.
- `album_asset` — join table (`albumId`, `assetId`), links `asset` ↔
  `album`.
- `album` — table is **singular** (`album`, not `albums`); columns include
  `id`, `albumName`, `description` (`text`, not null, defaults to `''`).

## Scope (Rod's account only, ownerId `cf0d38b8-611f-483c-a889-38ec7029909d`)

As of 2026-09-01:

- **Total missing-timezone assets: 9,262** (`asset_exif."timeZone" IS NULL`,
  `asset."deletedAt" IS NULL`).
  - **In at least one album: 5,072.**
  - **Not in any album: 4,190** — year distribution overwhelmingly falls in
    1979–2022 (heaviest 2003–2015), consistent with Rod's Pacific-timezone
    era (birth until moving to Kuna, ID in July 2024). Only 6 assets fall
    after the move (5 in 2026, 1 in 2025).

## Decided approach

**No single blanket rule applies across all albums.** Each album needs
individual judgment — some are single trips/events with one clear
location+date range (safe for one offset), others are topical collections
spanning years/locations (not safe for any single offset).

### In-album photos (5,072)

Tracked in `album-timezones.csv` (repo root) — one row per album:
`id, albumName, description, missing_tz_count, earliest, latest, offset, action`.
`action` is `apply <offset>` / `skip` / `split`, decided per row by Rod.

- **`Attention!` album (17 assets) → always `skip`.** Pre-existing catch-all
  for photos whose date couldn't be resolved by any means (see `DESIGN.md`)
  — not tied to one location, never gets a blanket timezone.
- **Topical (not date/location-bound) albums identified so far — action
  undecided, likely `skip` or `split`:**
  - `Family Reunion` (449 assets, 2007–2019) — all family reunions across
    many years combined into one album by design; dates alone identify the
    specific event, but a single offset would be wrong across years/venues.
  - `Andrew Slide` (84 assets, 2003–2014) — all of Andrew's (deceased,
    12 years ago) mission slides, kept in original form; topical, not
    trip-bound.
  - `Family History: Watkins` (681 assets, 2005–2022) — likely an
    accumulated scanned-photo collection, not one event.
  - Also flagged as wide-span and worth a second look: `Mission: Jared`,
    `Graduation: Jared`, `Family History: Barnes/Sheffield`.
- **Data-quality note:** the by-album query's date-range columns caught one
  real error — `Tour: 2017` (id `617add6d-5ceb-41d0-8556-33c2a5b52635`, "OR-
  ID-WY-MT" trip) showed a max date of 2026-05-20 despite being a 2017 trip
  album; one stray asset had the wrong date. Rod corrected it directly
  2026-09-01. Worth re-running the by-album query (see Reference below) if
  new anomalies are suspected before trusting any album's date range at face
  value.
- Several album names intentionally repeat across different album IDs (e.g.
  four separate `Tour: 2017` albums for distinct trips within the same
  year) — this doesn't break anything mechanically, since everything keys
  off `album.id`, not name. `album-timezones.csv` includes each album's
  `description` and date range specifically so duplicate-named rows are
  still distinguishable without opening the UI for each one.

### Non-album photos (4,190)

**Proposed, not yet built:** a date-boundary rule — Pacific time (birth
through 2024-07, DST-aware: PST `-08:00`/PDT `-07:00`) then Mountain time
(2024-07 onward: MST `-07:00`/MDT `-06:00`). Rather than applying this
blindly, group candidates into **temporary albums by date range** first for
manual visual review (same album-first-review pattern already established
for `Navy Years`, see `STATE.md`), then apply the reviewed offset per temp
album, then delete the temp albums once done. This also forgives any
travel/away-from-home-timezone photo that isn't already captured in a
proper album.

## Not yet built / open items

- The actual batch script: for a given set of asset IDs — resolve each to
  its library file path (`asset.originalPath`), write the offset via
  `exiftool -m -overwrite_original`, then batch-call
  `POST /api/assets/jobs {"name":"refresh-metadata","assetIds":[...]}`.
  Should follow existing script conventions in this repo (`.env`-next-to-
  script for the API key, absolute paths, etc. — see `import.sh`/
  `create-album.sh` in `DESIGN.md`).
- Temp-album creation/grouping logic for the non-album 4,190 (by date range,
  DST-aware) — not started.
- Rod is still filling in `album-timezones.csv` per-album decisions; script
  work is blocked on at least a first batch of decided rows to test against.

## Reference: commands used this session

Schema lookups:
```
docker exec -it immich-postgres psql -U immich -d immich -P pager=off -c "\d asset_exif" -c "\d asset" -c "\d album_asset" -c "\d album"
```

Scope/count query (missing timezone, in-album vs not):
```sql
SELECT (aa."assetId" IS NOT NULL) AS in_album, count(*)
FROM asset a
JOIN asset_exif e ON e."assetId" = a.id
LEFT JOIN album_asset aa ON aa."assetId" = a.id
WHERE a."ownerId" = 'cf0d38b8-611f-483c-a889-38ec7029909d'
  AND e."timeZone" IS NULL
  AND a."deletedAt" IS NULL
GROUP BY 1;
```

Non-album year distribution:
```sql
SELECT date_trunc('year', a."localDateTime") AS year, count(*)
FROM asset a
JOIN asset_exif e ON e."assetId" = a.id
LEFT JOIN album_asset aa ON aa."assetId" = a.id
WHERE a."ownerId" = 'cf0d38b8-611f-483c-a889-38ec7029909d'
  AND e."timeZone" IS NULL
  AND a."deletedAt" IS NULL
  AND aa."assetId" IS NULL
GROUP BY 1
ORDER BY 1;
```

Per-album detail (source of `album-timezones.csv`):
```sql
SELECT
  al.id,
  al."albumName",
  al.description,
  count(*) AS missing_tz_count,
  min(a."localDateTime")::date AS earliest,
  max(a."localDateTime")::date AS latest
FROM asset a
JOIN asset_exif e ON e."assetId" = a.id
JOIN album_asset aa ON aa."assetId" = a.id
JOIN album al ON al.id = aa."albumId"
WHERE a."ownerId" = 'cf0d38b8-611f-483c-a889-38ec7029909d'
  AND e."timeZone" IS NULL
  AND a."deletedAt" IS NULL
GROUP BY al.id, al."albumName", al.description
ORDER BY missing_tz_count DESC;
```

Single-file test (write + verify):
```
sudo exiftool -m -overwrite_original "-OffsetTimeOriginal=-06:00" "-OffsetTime=-06:00" <file>
exiftool -time:all -gps:all <file>
```
