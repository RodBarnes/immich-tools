# Immich Internals — Technical Reference

Durable, general-purpose facts about how Immich/Postgres/Docker behave in
this deployment, discovered across multiple topics. This is a reference
doc, not a topic with a state — nothing here is "in progress." See
`STATE.md` for the topic index if you followed a link here looking for an
active discussion.

## Database schema (v3.1.0, confirmed 2026-09-01)

- `asset` — `id`, `ownerId`, `originalPath`, `originalFileName`,
  `fileCreatedAt`/`fileModifiedAt`, `localDateTime` (`timestamptz`, not
  null — drives timeline grouping/sort/display, derived from EXIF+timezone
  at import time), `createdAt` (upload time), `deletedAt`.
- `asset_exif` — one row per asset (`assetId` FK, primary key). Includes
  `dateTimeOriginal`/`modifyDate` (UTC `timestamptz`), `timeZone` (nullable
  `character varying`), `latitude`/`longitude`, `city`/`state`/`country`,
  `description` (`text`, not null, default `''`).
- `album` — table is **singular** (`album`, not `albums`). Columns include
  `id`, `albumName`, `description` (`text`, not null, default `''`).
- `album_asset` — join table (`albumId`, `assetId`) linking `asset` ↔
  `album`.
- **`asset.originalPath` maps directly to the on-disk library path**
  (`/mnt/data/immich/library/library/<userId>/<YYYY>/<MM>/<filename>`).
  Querying `SELECT ... FROM asset WHERE "originalPath" LIKE '%<fragment>%'`
  reliably tells you whether a given on-disk path is a live, DB-tracked
  asset or a filesystem-only orphan (0 rows). Used both for the Karen/Rod
  mis-import identification (see `topics/karen-rod-misimport.md`) and for
  confirming stray/orphaned directories are harmless.
- **API vs. DB filtering:** `GET /api/assets` filters by photo EXIF date,
  not upload time — direct Postgres queries against `asset.createdAt` are
  needed to filter by when something was actually uploaded.

## Immich behavior

- **Does NOT retain history of soft-delete (trash)/restore events** — only
  permanent/hard deletes are audited (`asset_audit`, `album_asset_audit`,
  populated by `AFTER DELETE` triggers only). Once an asset is restored
  from trash, `asset.deletedAt` reverts to `NULL` and all trace is gone. A
  trash-related bug must be caught live (watch Trash view + tail logs) — no
  after-the-fact DB evidence exists.
- **Trashing an asset does not remove its row from `album_asset`** — the
  asset stays linked, the album just displays as empty/thumbnail-less
  because trashed assets are filtered from the view.
- **Picasa "date taken" fallback:** when a photo has no EXIF/IPTC date at
  all (confirmed via both Pillow and `exiftool` — genuinely absent, not
  hidden), Immich falls back to displaying the file's filesystem
  last-modified timestamp as the photo's date in the UI. This is a
  **display fallback only** — it does not write anything to the file, and
  it's separate from `exif-photos.sh`'s own stricter fallback chain (see
  `topics/exif-tools-pipeline.md`), which never uses filesystem timestamps
  as a date source.
- **EXIF GPS removal isn't possible from the Immich UI** — requires
  `exiftool` on the original file.
- The global Admin → Job Queues → "Extract Metadata" → "Missing" job only
  processes assets with no `asset_exif` row at all — it does not reprocess
  existing rows that are simply missing one field (confirmed via live test,
  see `topics/timezone-correction.md`). The per-asset "Refresh Metadata" UI
  action (`POST /api/assets/jobs {"name":"refresh-metadata","assetIds":[...]}`)
  does reprocess in that case.

## Docker / Postgres operational notes

- **`docker logs immich-server` shows only NestJS service/job logs** — no
  HTTP-level access logs by default.
- **Postgres query logs are NOT in `docker logs`**; written to files inside
  the `immich-postgres` container at
  `/var/lib/postgresql/data/log/postgresql-<date>.log`. Enable via
  `ALTER SYSTEM SET log_statement = 'all'; SELECT pg_reload_conf();` and
  revert to `'none'` after use.
- **Always pass `-P pager=off`** to `psql` run via `docker exec -it` —
  otherwise output goes into `less` inside the container tty and looks like
  a hang.
- **`\copy` in psql is a client meta-command**, not SQL — must run inside
  an interactive/scripted `psql` session (`-f script.sql`), not via `-c`.
  Also: `immich-postgres` only sees its own container filesystem, so files
  need `docker cp`'d in before `\copy FROM` can read them, and back out
  after `\copy ... TO` writes them.
- **Inline `-c "..."` with escaped `\"` identifier quotes is fragile**
  across a multi-line paste — quoting can silently get mangled. Prefer
  writing the SQL to a file (heredoc with a quoted `'EOF'` marker so bash
  doesn't touch its contents) and running `psql -f`, then `docker cp` the
  file in first.
- **Docker `-v` bind mounts require an absolute host path.** A relative
  path is silently interpreted as a *named volume* instead. A relative path
  containing `/` gets rejected outright ("invalid characters for a local
  volume name"); a bare single-word relative path (e.g. `immich`) silently
  creates a fresh, empty named volume with that name instead of erroring —
  so a script mounting it reports "no files found" even though the intended
  source directory exists. See `topics/import-sh.md` for where this bit.

## Bash/shell gotchas

- **Complex `[[ =~ ]]` regexes with character classes or alternation must
  be stored in a variable first** — inline complex patterns fail silently
  in bash. Standing rule for any pattern work in these scripts.
- **`read -r -d ''` clears its variable on the final (EOF) call**, at least
  on bash 5.2.37 (confirmed on `boss`). A `while read -d '' match; do ...
  done < <(find ...)` loop leaves `$match` empty immediately after the loop
  ends, even though it held a value on the last successful iteration. Fix:
  capture the value into a separate variable inside the loop body before it
  can be cleared.
- **`find -newermt` compares mtime, not ctime.** `exiftool` preserves a
  file's original modification time by default, so files processed today
  can still show an old mtime — `-newermt` will miss them. Use `-newerct`
  to compare ctime (inode change time), which reflects when the file was
  actually written to the current filesystem.

## Infrastructure notes (not tool-specific)

- **Cloudflare must be DNS-only** for `photos.advappsw.com` /
  `cloud.advappsw.com` — proxied mode double-terminates TLS and imposes
  upload size limits incompatible with Immich/Nextcloud.
- **Caddy + symlinked Caddyfile:** Docker binds to the inode at container
  creation; if the Caddyfile becomes a symlink afterward, the container
  keeps the stale inode and needs recreation, not just a reload.

## Metadata-repair techniques

- **`exiftool -TagsFromFile <original> <edited>` restores metadata GIMP
  strips on export.** Confirmed 2026-08-15: GIMP's JPEG export produces a
  file with zero EXIF at all. Copies the full tag set from an untouched
  original onto an edited file — verified via `exiftool -s` diff
  (`DateTimeOriginal`, `CreateDate`, `Make`, `CameraModelName`,
  `Orientation`, `ImageSize` all matched afterward; remaining differences
  were harmless JPEG re-encoding artifacts, not metadata loss). Applies to
  any Picasa/GIMP-edited photo.
- **ImageMagick `compare -metric AE` needs a `-fuzz` threshold to be
  useful** for comparing two separately-saved JPEGs — lossy recompression
  alone shifts nearly every pixel by 1+/255, making AE read as "almost the
  entire image differs" even for visually identical files. `-fuzz 5%`
  worked well to get a meaningful changed-pixel count (used to confirm a
  Picasa `Originals/` pair was a real edit, not just recompression noise —
  see `topics/family-folder-import.md`).
