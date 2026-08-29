# Incident: Creating an Album Put Photos in Trash

_Date of incident: 2026-07-23, before 5pm Mountain (~22:00-23:00 UTC)._
_Investigated: 2026-07-23/24, across sessions on `deft` and `brawn`._
_Immich version: 2.7.5._

## What happened

1. Rod selected a batch of photos (originally recalled as "June 20," later
   corrected to **May 20**) from the timeline that had no date metadata.
2. Clicked to add them to an album, typed the name **"Imported"**, and
   created it.
3. The album appeared in the album list with a thumbnail, as expected.
4. Shortly after, the photos disappeared, the album thumbnail went blank
   (grey square), and the album list showed **"Imported" with 0 items**.
5. The photos were not findable under "Photos" either.
6. Separately, and without Rod doing anything with it, the **existing**
   album **"2026 Ride Photos"** also lost its assets the same way — that
   album's 5 photos (dated May 23) also ended up trashed. Rod was not
   working in or with that album at the time.
7. Checking the Immich **Trash** confirmed both sets of photos were there
   (not lost) — this explained both symptoms: the disappearance and the
   0-item album count.
8. Rod restored the affected photos from both "Imported" and "2026 Ride
   Photos" via Trash. Restoration was successful.
9. Rod later attempted to reproduce the issue deliberately and **could not
   reproduce it**.

## Investigation performed

### GitHub issue / changelog search
Searched immich-app/immich issues and v2.7.0–v2.7.5 release notes for a
matching report. **No confirmed match found.** Closest related-but-different
issues:
- [#15646](https://github.com/immich-app/immich/issues/15646) / [PR #28985](https://github.com/immich-app/immich/pull/28985) —
  album item counts/thumbnails can go to 0 once *every* asset in an album is
  trashed by some other means; a *display* bug for already-trashed assets,
  not a cause of trashing.
- [#11498](https://github.com/immich-app/immich/issues/11498) — old
  (v1.111, mobile) bug where "Remove from album" incorrectly trashed the
  asset. Fixed in 2024; wrong platform/action for this incident.
- [#23150](https://github.com/immich-app/immich/issues/23150),
  [#20674](https://github.com/immich-app/immich/issues/20674),
  [#30042](https://github.com/immich-app/immich/issues/30042),
  [#27124](https://github.com/immich-app/immich/issues/27124) — other
  album/cross-tab bugs, none matching the reproduction steps or v2.7.x.

No v2.7.x changelog entry references album creation or trash interaction.

### Server log check
`docker logs immich-server` does **not** contain HTTP-level access logs
(no request/response lines) by default — only NestJS service/job log
output (e.g. scheduled jobs, thumbnail generation). Grepping for
`trash|DELETE /api/asset|album` in the incident window returned nothing
useful for this reason; this approach can't reveal what API calls were
made unless verbose HTTP logging is explicitly enabled.

Two unrelated ERROR lines were found in the logs (`AssetGenerateThumbnails`
job, `ImproperImageHeader` from ImageMagick's TGA decoder, for
`0312Elow.jpg` / `0312Blow2.jpg`) — determined to be unrelated: different
asset owner (not Rod's account), timestamped 12:00 AM (midnight, a routine
scheduled-job slot), and about thumbnail generation, not delete/trash.

### Database investigation
- `asset.deletedAt` / `updatedAt` — queried directly for the incident
  window; showed exact trash timestamps for assets **still in Trash at
  query time**. This is reliable ground truth *while an asset remains
  trashed*, but once restored, `deletedAt` reverts to `NULL` and the
  evidence is gone.
- `asset_audit` table (columns: `id`, `assetId`, `ownerId`, `deletedAt`) —
  queried for the incident window: **0 rows**. Its schema is populated by
  an `AFTER DELETE` trigger (confirmed via `\d album` showing
  `album_delete_audit AFTER DELETE ON album ... EXECUTE FUNCTION
  album_delete_audit()`), meaning it only logs **permanent/hard deletion**
  (for sync tombstone purposes), never soft-delete (trash) or restore.
- `album_asset_audit` table (columns: `id`, `albumId`, `assetId`,
  `deletedAt`) — same DELETE-trigger pattern. Queried for the "2026 Ride
  Photos" album (`id = 7e91eee1-9966-4368-b3d9-e472bcb7de2b`): **0 rows**.
  This confirms trashing an asset does **not** delete its row from the
  `album_asset` join table — trashing is purely a column update
  (`asset.deletedAt`) on the `asset` table itself. The album's assets stay
  linked underneath; the album just displays as empty because trashed
  assets are filtered out of the count/view.

## Conclusion

**Root cause not identified and, based on everything checked, not
recoverable after the fact.** Immich does not appear to retain any
queryable history of soft-delete (trash) or restore events per asset —
only permanent/hard deletions are audited. Once an asset is restored,
`asset.deletedAt` reverts to `NULL` and all trace of the original trash
event is gone; there is no separate history/log table that captures it.

Rod attempted to deliberately reproduce the issue and was not able to.
Without a reproduction and without log/DB evidence, there isn't enough to
file a useful GitHub issue (no clear repro steps to give maintainers).

## If this happens again

To actually catch this live (the only way to get real evidence, given the
DB retains no history):
1. **Watch the Trash view in real time** while performing the album
   action, rather than checking after the fact.
2. **Tail server logs live**: `docker logs -f immich-server` in a second
   terminal while reproducing, though note this won't show HTTP-level API
   calls unless verbose/debug HTTP logging is explicitly enabled first —
   worth enabling temporarily if trying to catch this again.
3. Immediately after noticing assets missing, **query
   `asset.deletedAt`/`updatedAt` before restoring anything** — this is the
   only reliable timestamp source, and it's destroyed the moment you
   restore.
4. Check whether **other albums** you weren't actively working with are
   also affected (as happened with "2026 Ride Photos") — this may indicate
   scope (e.g. did it affect every album with recently-modified assets, or
   something else) if it recurs.
5. Note whether multiple browser tabs/windows or the mobile app were open
   at the time — ruled out for this incident (confirmed single tab, no
   other client), but worth re-checking if it recurs.

## Useful commands for next time

Get DB credentials (on `boss`):
```
sudo grep -E "^DB_USERNAME|^DB_DATABASE_NAME" /opt/immich/.env
```

Check currently-trashed assets in a time window:
```
sudo docker exec -it immich-postgres psql -U immich -d immich -c "SELECT id, \"originalPath\", \"deletedAt\", \"updatedAt\" FROM asset WHERE \"deletedAt\" BETWEEN '<start>' AND '<end>' ORDER BY \"deletedAt\";" -P pager=off
```

Look up an album's ID by name:
```
sudo docker exec -it immich-postgres psql -U immich -d immich -c "SELECT id, \"albumName\" FROM album WHERE \"albumName\" = '<name>';" -P pager=off
```

Check audit tables (permanent-delete only, not trash/restore):
```
sudo docker exec -it immich-postgres psql -U immich -d immich -c "SELECT * FROM asset_audit WHERE \"deletedAt\" BETWEEN '<start>' AND '<end>' ORDER BY \"deletedAt\";" -P pager=off
sudo docker exec -it immich-postgres psql -U immich -d immich -c "SELECT * FROM album_asset_audit WHERE \"albumId\" = '<album-id>' ORDER BY \"deletedAt\";" -P pager=off
```

Note: always append `-P pager=off` to avoid the output going into `less`
inside the container's tty, which can otherwise appear to "hang" the
terminal (it's waiting for `q`, not actually stuck).
