# "Imported" Album Shows 0 Items

## State

**Parked, diagnosis paused since 2026-08-08.** No further progress since.

On 2026-07-27, Rod reported: a batch of ~undated photos imported
2026-06-20 (all landed on that date since they had no date metadata) was
selected in the Immich UI and added to a newly-created album called
"Imported." The album now shows 0 items, and the photos can't be found in
the main timeline under June 20 either.

**Ruled out so far:**
- Not a stale-UI-cache issue — hard refresh (Ctrl+Shift+R) made no
  difference.

**Where it was left:** about to query the Immich API directly (bypassing
the UI) to see whether the server itself reports 0 assets for the album:
```
curl -H "x-api-key: $KEY" https://photos.advappsw.com/api/albums
```
First attempt returned a 104-byte response that `jq '.[] | select(...)'`
couldn't index as an array (likely an error object — `$KEY` unset or
invalid — rather than the expected album list). Rod was about to re-run
without the `jq` filter to see the raw response and confirm `$KEY` is set,
but the session paused before that came back. **Pick up exactly here.**

## Design (planned diagnostic sequence, none of it executed yet)

1. Get the album's `id` and `assetCount` per the server (`/api/albums`).
2. `GET /api/albums/<id>` and check `.assets | length` — confirms whether
   the DB itself has 0 linked assets (server-side problem) vs. a UI-only
   bug.
3. Search the main timeline/Trash for the June 20 photos by date or
   filename to determine whether the assets exist at all, independent of
   the album question.
4. Only after root cause is confirmed (UI bug / failed album-link write /
   assets trashed or missing / wrong-account association) decide on a fix
   — no changes have been made yet, this is still pure diagnosis.

Note: given the Karen/Rod cross-account mis-import incident (see
`topics/karen-rod-misimport.md`), a wrong-account association is a
low-probability but not-yet-ruled-out possibility worth checking if the
above steps don't explain it.
