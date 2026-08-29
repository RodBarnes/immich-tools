# Immich filename search failure — investigation notes

## Status: RESOLVED (2026-08-16)
Root cause confirmed via live debug instrumentation and fixed by correcting the corrupted `fileCreatedAt`/`localDateTime` on one asset. Filename search for "2009" and the asset detail view both work correctly now. See "Resolution" section near the bottom for the final steps taken.

## Symptom
- Searching by filename for anything containing "2009" fails with a UI error tag: "Error Failed to search assets (Immich Server Error)".
- Other filename searches work fine.
- Assets are still present and browsable via the timeline scrollbar — only the filename search endpoint fails.
- Originally triggered while editing dates on several `2009-11-*.avi` files; crash first appeared after editing one of them mid-session.
- Confirmed still reproducing as of this writing; not a browser cache issue (tested with a fresh Brave session).

## Environment
- Host: `boss`, Immich deployed via Docker Compose in `/opt/immich`.
- Containers: `immich-server`, `immich-postgres` (image `tensorchord/pgvecto-rs:pg14-v0.2.0`), `immich-redis`, `immich-machine-learning`.
- Server version: v3.1.0 (per `[Microservices:VersionService] Found v3.1.0` log line).
- DB: Postgres, database `immich`, user `immich`. Connection env vars confirmed via `docker exec immich-server printenv`.

## Root cause identified (partially)
Server logs (`docker logs immich-server`) show a consistent stack trace whenever the "2009" filename search is attempted:

```
RangeError: Invalid time value
    at Date.toISOString (<anonymous>)
    at asDateString (/usr/src/app/server/dist/utils/date.js:6:34)
    at mapAsset (/usr/src/app/server/dist/dtos/asset-response.dto.js:327:48)
    at /usr/src/app/server/dist/services/search.service.js:170:80
    at Array.map (<anonymous>)
    at SearchService.mapResponse (/usr/src/app/server/dist/services/search.service.js:170:31)
    at SearchService.searchMetadata (/usr/src/app/server/dist/services/search.service.js:55:21)
```

- Line 327 of `asset-response.dto.js` (in the running container) is confirmed, by direct inspection of the compiled file, to be:
  `fileCreatedAt: (0, date_1.asDateString)(entity.fileCreatedAt),`
- `asDateString` (in `utils/date.js`) is simply `x instanceof Date ? x.toISOString() : x`.
- This means: for some asset returned by the "2009" filename search, `entity.fileCreatedAt` is a JavaScript `Date` object whose internal time value is `NaN` (an "Invalid Date"), and calling `.toISOString()` on it throws. Because `mapResponse` builds the whole response via `.map()`, one bad asset poisons the entire search response with a 500 error — explaining why the whole search fails rather than just omitting one result.
- Confirmed via the stack trace that this is **not** the EXIF `modifyDate`/`dateTimeOriginal` fields (a similar-looking but different bug reported in immich-app/immich issue #16686) — a crash in `mapExif` would show its own stack frame, and none appears. This is specifically the `asset.fileCreatedAt` column value, as consumed directly in `mapAsset`.

## What we ruled out
- Checked `asset` table schema: `fileCreatedAt`, `fileModifiedAt`, `localDateTime`, `createdAt`, `updatedAt` are all `NOT NULL` timestamptz columns — so it can't be a plain `NULL`.
- Found one clearly corrupted row while eyeballing data: asset `722c9963-4d92-47df-ab08-2ba5e481e338` (`2009-11-26 14-24-33.avi`) has `fileCreatedAt = 0026-11-15 02:47:49+00` and `localDateTime = 0026-11-14 18:47:49+00` (year 26 instead of 2009) — almost certainly a mistake made while manually editing the AVI dates. **However**, traced through the actual parsing library (`postgres-date`, used by the `pg` driver) and confirmed a year value like 26 is handled correctly (there's an explicit `date.setUTCFullYear(year)` fixup for years 0–99) and does **not** produce `NaN`. So this row is bad data worth fixing, but is not, by itself, confirmed to be the cause of the crash.
- Grepped the compiled server code for `setTypeParser` — no custom Postgres type parsers registered, so date parsing behavior should be the Node default (matches what a plain `pg.Client` does).
- Captured the *exact* SQL query Immich runs for this search (via temporarily enabling `log_statement = 'all'` on Postgres, reproducing the failure, and reading `/var/lib/postgresql/data/log/postgresql-<date>.log` inside the `immich-postgres` container — `docker logs` does not show Postgres query logs because it uses the logging collector, writing to files instead of stdout). The query:
  ```sql
  select to_json("asset_exif") as "exifInfo", "asset".*
  from "asset"
  inner join "asset_exif" on "asset"."id" = "asset_exif"."assetId"
  where "asset"."visibility" = 'timeline'
    and "asset"."ownerId" = any('{cf0d38b8-611f-483c-a889-38ec7029909d}'::uuid[])
    and f_unaccent(asset."originalFileName") ilike '%' || f_unaccent('2009') || '%'
    and "asset"."deletedAt" is null
  order by "asset"."fileCreatedAt" desc
  limit 251 offset 0
  ```
- Confirmed (by matching timestamps precisely, `01:56:44`) that this exact query execution corresponds to the exact server crash in the same second.
- **Puzzle**: re-running this exact query (same SQL, same parameters, same `pg` driver, from inside the `immich-server` container) immediately afterward returns 37 rows, all with valid `fileCreatedAt` values — no `NaN` found. Also separately scanned the *entire* `asset` table (26,436 rows) for any row with an invalid `fileCreatedAt` — none found. So the external, out-of-band SQL reproduction cannot find the bad value, even though the live server demonstrably crashes on this exact query every time it's actually run through the app.
- Confirmed via `docker logs immich-server --since ...` / `--tail` that the crash is 100% reproducible right now (as of this session), not a stale/cached browser error, and no new imports/edits have been made in the meantime.
- Checked immich-app/immich GitHub issues for similar reports — issue #16686 has the same error message and stack shape but for the `modifyDate` EXIF field, not `fileCreatedAt`; ruled out as the same bug based on stack trace shape (see above). No other matching issue found for `fileCreatedAt` specifically causing this crash.

## Working theory
The discrepancy between "live server crashes on this query" and "manually re-running the same query externally succeeds" is unexplained so far. Possibilities not yet tested:
- Some difference between the app's live Kysely/`pg` connection pool and our ad-hoc `pg.Client()` (e.g., different `pg` internals loaded, session-level settings) that affects how a specific edge-case timestamp value parses.
- A genuinely transient/racy condition.
- Something about the live request path that isn't fully captured by replaying the logged SQL text and parameters alone.

Rather than keep guessing, the plan is to instrument the actual running code directly.

## Resolution (executed 2026-08-16)

Rather than keep guessing at the external-reproduction discrepancy, we instrumented the actual running code directly:

1. Patched `/usr/src/app/server/dist/dtos/asset-response.dto.js` inside the `immich-server` container: wrapped the `fileCreatedAt` line in a try/catch that logs `entity.id`, `entity.originalFileName`, and the raw `entity.fileCreatedAt` value before re-throwing (so the crash still happened exactly as before, but was now logged with full context). Applied via a Node one-liner doing an exact string replacement (verified the exact patched line afterward with `grep` to rule out a shell `!` history-expansion mishap — the edit was clean).
2. `docker restart immich-server` to load the patched file (a plain restart preserves the container's writable layer, so the edit survives — only a recreate discards it).
3. Reproduced the "2009" filename search failure in the browser.
4. Pulled the debug log (`docker logs immich-server --tail 50 | grep -A3 BAD_DATE_DEBUG`) and got a direct hit:
   ```
   BAD_DATE_DEBUG {"id":"722c9963-4d92-47df-ab08-2ba5e481e338","name":"2009-11-26 14-24-33.avi","fileCreatedAt":null}
   ```
   (`fileCreatedAt: null` here is `JSON.stringify()`'s standard behavior for an Invalid `Date` object — not a literal SQL `NULL`.) This confirmed the exact same asset flagged earlier as suspicious (the "year 0026" row) was in fact the trigger, live, in the real request path.
5. Independently corroborated via the Immich UI: scrolled the timeline to the bottom, found a stray "26" year bucket, and located the same AVI file shown under "Fri, Nov 13, 26". Clicking it to view/edit triggered its own separate crash — "Failed to get asset info (HTTP 500)" — same root cause (any code path running this asset through `mapAsset` hits the broken `fileCreatedAt`). The timeline's month/year grouping view itself didn't crash because it uses a "stripped" response variant that only touches `localDateTime`, not `fileCreatedAt`.
6. Backed up the `asset` table before making any data change: `docker exec immich-postgres pg_dump -U immich -d immich -t asset > ~/asset_table_backup_20260816_151747.sql` (14 MB, saved to `/home/rod/`).
7. Fixed the corrupted row directly via SQL, using the correct date/time embedded in the filename itself (`2009-11-26 14-24-33.avi`):
   ```sql
   UPDATE asset SET "fileCreatedAt" = '2009-11-26 14:24:33+00', "localDateTime" = '2009-11-26 14:24:33+00'
   WHERE id = '722c9963-4d92-47df-ab08-2ba5e481e338';
   ```
   Verified via `SELECT` that the row updated correctly. Did not touch `fileModifiedAt` (still shows an unrelated/likely-also-wrong batch-reprocessing artifact, `2009-12-14 06:47:49+00`, but this field wasn't implicated in any crash, so left alone).
8. Verified in the UI: the "26" bucket disappeared from the timeline immediately. Filename search for "2009" no longer errors. The asset's detail panel initially still displayed the *old* pre-fix date (`Nov 14, 26 ... GMT-08:00`, i.e. exactly the old `0026-11-15 02:47:49 UTC` value) despite the database being confirmed correct — a caching artifact (Immich's web client uses a service worker; a server-side Redis cache is also plausible). This resolved itself once the date was directly edited/re-saved through the Immich UI's own date editor, which correctly displays and persists the fix now.
9. Reverted the debug patch by recreating the container from the original image: `cd /opt/immich && docker compose up -d --force-recreate immich-server`. Confirmed clean revert: `docker exec immich-server grep -n "BAD_DATE_DEBUG" /usr/src/app/server/dist/dtos/asset-response.dto.js` returned nothing. Container came back up healthy.

### Open/unresolved side notes (not blocking, low priority)
- Never fully explained *why* external SQL reproduction (via a bare `pg.Client()`, and even a full 26,436-row table scan) consistently found this row's `fileCreatedAt` parsing to a **valid** Date (`0026-11-15T02:47:49.000Z`, not NaN), while the live app's own Kysely-based query pipeline turned the same underlying value into an Invalid Date at the exact same moment. Once the live debug log conclusively identified the offending asset, this discrepancy became academic and wasn't chased further. If this class of bug recurs on a different asset, worth revisiting (was about to check for Kysely plugins/transforms in `database.repository.js` when the issue was independently confirmed via the UI instead).
- `fileModifiedAt` on this asset (and several date inconsistencies among sibling `2009-11-26` files noted during investigation — multiple different filenames sharing identical, filename-mismatched timestamps) suggest some prior bulk operation scrambled a batch of these AVI dates unrelated to today's crash. Worth a manual sanity pass over that batch if accuracy of those dates matters, but none of them are known to cause crashes.

## Useful commands reference
- Enter Postgres: `docker exec -it immich-postgres psql -U immich -d immich --pset pager=off`
- List containers: `docker-ps` (user's alias) or `docker ps`
- Tail server errors: `docker logs immich-server --tail 100 2>&1 | grep -B5 -A15 -i "RangeError\|ERROR"`
- Postgres query log location (inside `immich-postgres` container): `/var/lib/postgresql/data/log/postgresql-<date>.log`
- Toggle Postgres statement logging (already reverted after use):
  ```sql
  ALTER SYSTEM SET log_statement = 'all';  -- or 'none' to revert
  SELECT pg_reload_conf();
  ```
