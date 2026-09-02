# Timezone Correction for Already-Imported Photos

_Started: 2026-09-01_

Spun out from `STATE.md` per the 2026-09-01 decision to keep individual
discussion topics in their own file rather than letting `STATE.md` grow
unwieldy — see `STATE.md`'s "Related Topic Docs" section.

## State (2026-09-02)

Active. Last worked: confirmed the write-offset mechanism is purely
additive (doesn't shift clock time — see Confirmed mechanism below),
decided the batch tool can apply an album's offset unconditionally
without checking existing `timeZone` state, identified 33 albums that can
be excluded entirely (already fully timezone'd), and hit an open anomaly
where DB `timeZone` doesn't always match file EXIF (see that section
below).

**Next:**
- `album-timezones.csv` (repo root) is **stale** — album names in it
  predate the album-rename pass (see `topics/album-naming-policy.md`) and
  it was never actually filled in beyond one row (`Attention!` → `skip`).
  Needs regenerating via the per-album query (Reference below), now that
  the 33 fully-covered albums can be dropped from it entirely.
- Per-album `offset`/`action` decisions still need to be made for the
  remaining albums (topical/multi-year ones flagged under "Decided
  approach" below still need `skip`/`split` judgment calls).
- The batch script itself (write offset to file + call
  `refresh-metadata`) is not yet built — see "Not yet built" below.
- New tool this session: `album-photo-metadata.sh` (repo root) — given an
  album name or id, dumps filename/timestamp/timezone/GPS/camera to CSV
  for manual inspection. Must run on `boss` (calls `docker exec
  immich-postgres` directly). Not yet committed — created but untested by
  Rod as of session end.

## Goal

A large number of photos already imported into Immich have no timezone
recorded (`asset_exif.timeZone IS NULL`) because the source EXIF never had
one. Resolve this now that the photos are already in Immich, rather than
re-running the original `bard`/Google-Photos import pipeline.

**Why it matters (2026-09-02):** the current mix of photos with and
without a recorded timezone causes incorrect sort order when viewing the
timeline in Immich. This effort accepts the camera's recorded clock time
as ground truth (no other reference exists) — the goal is to make
timezones consistent/present, not to correct clock time itself (see the
2026-09-02 confirmation below that writing an offset only labels the
existing time, never shifts it).

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
- **Confirmed (2026-09-02, `100_0092.jpg`): writing the offset does not
  shift the displayed/stored clock time, only labels it.** `Date/Time
  Original`/`Modify Date`/`Create Date` were `2017:07:19 10:25:40` (no
  zone) before the write; after `exiftool -m -overwrite_original
  "-OffsetTimeOriginal=-06:00" "-OffsetTime=-06:00"`, the clock value was
  unchanged (`2017:07:19 10:25:40-06:00` — offset appended, not applied as
  a shift) and the two new `OffsetTime`/`OffsetTimeOriginal` tags were
  added. Immich UI showed `Jul 19, 2017 Wed 10:25:40 AM` (no zone) before
  the refresh, and `Jul 19, 2017 Wed, 10:25:40 AM GMT-06:00` after — same
  clock time, zone label added. So this workflow is safe for photos whose
  recorded local time is already correct and only the zone is missing; it
  is **not** a tool for correcting a wrong clock time (e.g. a camera whose
  clock was never adjusted after travel) — that would need a separate
  time-shift edit, not just an offset write.
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

### Albums excluded — already fully have timezone (2026-09-02)

33 albums have zero assets missing a timezone (query in Reference below)
and are excluded from all further review/processing in this topic:

`50-Miler`, `Champoeg`, `City Museum`, `Cruise: Eastern Caribbean`,
`Cruise: Western Caribbean`, `Graduation: Lucas`, `House: Columbus`,
`House: Dads Lane`, `House: North Albany`, `Hummingbirds`, `Memorial
Ride`, `Moaning Caverns`, `Ride: Columbia River`, `Ride: Faragut`, `Ride:
Klickitat River`, `Ride: Lake Coeur d'Alene`, `Ride: Rainier`, `Ride:
Thompson Falls`, `Ride: Tillamook State Forest`, `Shoshone Falls`, `Sweet
Creek Falls`, `Tour: Colorado & Utah`, `Tour: PNWGT` (6 distinct albums
share this name), `Vacation: Golden Spike`, `Vacation: Naperville`,
`Warbird Roundup`, `Wedding: Karen & Rod`, `Wedding: Laura & Todd`.

Note: `Ride: Columbia River` appears here (fully has timezone) as well as
in the working set below under an older name/id from before the album
rename pass — these are two distinct album IDs that happen to now share a
name; not a conflict, just a reminder that name alone doesn't identify an
album (see `topics/album-naming-policy.md`).

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
  still distinguishable without opening the UI for each one. **Superseded
  by a naming policy decided 2026-09-01** — see
  `topics/album-naming-policy.md`: using Immich's "Group by year" album
  view lets the year drop out of the name entirely (e.g. `Tour: Canada`
  instead of `Tour: 2017`), so this disambiguation workaround won't be
  needed for newly-renamed albums going forward.

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

## Decided: batch tool applies unconditionally, no `timeZone IS NULL` check (2026-09-02)

Since writing `OffsetTimeOriginal`/`OffsetTime` never alters the underlying
clock value (confirmed above), the batch tool does not need to check
whether an asset already has a timezone before writing. Once an album's
offset is decided (`action`/`offset` in `album-timezones.csv`), apply it
to **every** asset in that album unconditionally — any asset that already
carried a different offset is deliberately overridden by that per-album
decision, not a bug to guard against. The `timeZone IS NULL` scoping used
in the discovery queries above was only for finding candidate
albums/photos to review; it is not a constraint the tool itself needs to
enforce.

## Open anomaly: DB `timeZone` can apparently diverge from file EXIF (2026-09-02)

**Confirmed on `IMG_0518.jpg`** (in the excluded `50-Miler` album, Canon
PowerShot A70 / Kodak scanner source, no GPS): the DB reports
`asset_exif.timeZone = UTC-7` for this asset, but `exiftool -time:all` on
the live library file shows **no `OffsetTime`/`OffsetTimeOriginal` tags at
all** — only bare `DateTimeOriginal`/`ModifyDate`/`CreateDate`, no offset.

This contradicts the mechanism confirmed and relied on elsewhere in this
doc (write offset to file → "Refresh Metadata" → DB reflects the file).
For this asset, the DB's timezone did not come from the file. Cause
unconfirmed — possibly Immich's "Edit date & time" UI can set a timezone
that's stored DB-only without writing it back to EXIF, possibly something
else. Not investigated further yet.

**Why this matters, not just curiosity:** it means `asset_exif.timeZone`
is not guaranteed to reflect what's actually written to the file on disk.
Practical risks this creates for the current effort:
- The "33 albums already fully have timezone" exclusion list (queried
  from the DB) may include assets whose timezone exists **only** in the
  DB — if the file is ever re-extracted/re-processed from disk (recall:
  metadata re-extraction reads from the file, not the DB — see "Confirmed
  mechanism" above), that DB-only value could be silently lost.
- Can't yet fully trust that "DB shows a timezone" ⇒ "file has a matching
  offset tag" for any asset not personally verified by both DB query and
  file-level `exiftool` check.

**Not yet resolved / would need further investigation:** whether Immich's
UI has an edit path that writes DB-only, and if so, whether it can be
made to also write the file (or whether this batch of assets should be
re-synced file-side to be safe).

**Source-side context (Rod, 2026-09-02):** this photo came from Google
Photos; before that, it would only have been touched by the (now
discontinued) Picasa desktop app during the years it was used. Neither is
expected to have written EXIF offset tags — consistent with the file
showing none. Leading candidate explanation is a manual per-photo edit
made through Immich's own UI at some point that isn't remembered/recorded
— plausible but not confirmed.

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

Albums with zero missing-timezone assets (source of the excluded list above):
```sql
SELECT al.id, al."albumName", count(*) AS total_assets
FROM album al
JOIN album_asset aa ON aa."albumId" = al.id
JOIN asset a ON a.id = aa."assetId"
JOIN asset_exif e ON e."assetId" = a.id
WHERE a."ownerId" = 'cf0d38b8-611f-483c-a889-38ec7029909d'
  AND a."deletedAt" IS NULL
GROUP BY al.id, al."albumName"
HAVING count(*) FILTER (WHERE e."timeZone" IS NULL) = 0
ORDER BY al."albumName";
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
