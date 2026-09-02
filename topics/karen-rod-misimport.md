# Karen/Rod Cross-Account Mis-Import Correction

## State

**In progress.** A batch of bard photos (two sub-batches, 1979–1985 and
1991–2007, both imported 2026-07-21) was mistakenly imported into Karen's
Immich account instead of Rod's. The 2554 mis-imported assets were
identified precisely and moved to trash in Karen's account via `DELETE
/api/assets` (not yet emptied).

- **Re-copy from `bard` to staging:** done (per Rod, 2026-08-08).
- **Count verification:** in progress. A `find <dir> -type f | wc -l`
  comparison between the staging copy and `bard` showed a ~500 file
  discrepancy. Likely explanation: content under `Collections/` (e.g.
  `Navy Years/`, already processed/imported separately) inflates one
  side's count. Adjusted command provided —
  `find . -type f -not -path './Collections/*' | wc -l` (or `-not -path
  '*/Collections/*'` if `Collections` can appear at more than one depth) —
  to run on both sides. **Result not yet confirmed back.**
- **Remaining after counts confirmed to match:** re-run `exif-tools` on
  the fresh copy, `import.sh` into **Rod's** account, verify, then empty
  Karen's trash for these assets.

Note: no `ts-backup` snapshot covers this — the working path `~/tmp` on
`boss` is excluded from `ts-backup` by default. This didn't matter in the
end, since `exif-tools` was run on the boss-side staged copy, not the
originals on `bard`, so the source data on `bard` was never altered and
needed no restore.

### Related, separately-resolved incident

An earlier batch (~3,258 assets) of Karen's Google Photos was accidentally
imported into **Rod's** account on 2026-06-15 — the reverse direction of
the main incident above. Identified via a direct Postgres query
(`createdAt` on `asset`, since the API only filters by EXIF date) and
removed via `DELETE /api/assets` (trashed, not yet emptied). Karen's
photos were then re-downloaded and imported using her own API key and a
separate import script. Trash emptying deferred until the main incident
above is also confirmed fully resolved.

### Known harmless oddities found during this investigation (parked, 2026-08-08)

- Rod's Immich library
  (`/mnt/data/immich/library/library/cf0d38b8-.../`) has a directory
  literally named `198` (not `1980`) containing a single empty
  subdirectory `05`. Confirmed via direct Postgres query that **no
  current asset references this path** (0 rows) — a filesystem-only
  orphan, not something Immich still tracks. How it was created is
  unknown, not investigated further. Decision: leave it; watch for
  recurrence when next importing something dated 1980.
- Karen's Immich library root has a self-referential symlink — named with
  Karen's own user UUID, pointing back to that same absolute path (dated
  Jul 22 08:11). No explanation found; confirmed harmless. Decision: leave
  it, strange but inert.
- Two files found in Karen's `1980/08/` during this investigation
  (`Barnes3.jpg`, `Barnes8.jpg`, mtime `Jul 21 17:05`) are very likely part
  of the still-trashed (not yet purged) mis-import batch above — mtime
  matches that batch's 2026-07-21 import date, and Immich trash doesn't
  remove files from disk until emptied.

## Design (identification method)

**Identifying a mis-imported batch by `createdAt` time window alone is
unreliable** if the target account has other activity in the same window
(e.g., mobile app background auto-backup uploading the owner's own recent
photos coincidentally during the same period) — this pulled in unrelated
rows and, separately, missed part of the actual batch (whose sub-batches
were imported at different times than assumed).

**The reliable method:** enumerate the exact files by filesystem `ctime`
(`find -newerct`, not `-newermt` — see `topics/immich-internals.md` for why
mtime doesn't work here, since `exiftool` preserves original mtime), then
join against `asset.originalPath` in Postgres. This ties the DB row
directly to the exact on-disk file rather than inferring from timestamps.
