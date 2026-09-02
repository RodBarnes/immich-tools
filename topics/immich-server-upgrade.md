# Immich Server Upgrade (v2.7.5 → v3.1.0)

## State

**Fully complete** (2026-08-28). All four staged steps done and
independently verified: VectorChord migration, fresh backup checkpoint,
v3.0.3, v3.1.0.

## Design

### Why staged rather than a direct jump

Given a documented unresolved data-loss report on the exact 2.7.5→3.0.0
path (GitHub issue `immich-app/immich#29445` — missing photos/videos,
license key, and recent user accounts after that exact upgrade, closed
without a confirmed root cause) and a required Postgres vector-extension
migration that's a prerequisite for reaching v3.0.0 at all, the upgrade was
staged into four checkpointed steps:

1. VectorChord migration (pgvecto.rs → VectorChord)
2. Fresh backup checkpoint
3. Upgrade to v3.0.3 (v3.1.0's changelog lists this as its own minimum
   required prior version — a required stepping stone, not optional)
4. Upgrade to v3.1.0

### Version-history discrepancy (resolved)

Earlier docs had misread Immich's periodic update-checker log line
(`[Microservices:VersionService] Found v3.1.0, released at 7/29/2026`) as
the server's own running version. That line is only the update checker
reporting the latest available release — boss had been running v2.7.5the
entire time until this project, confirmed via both the Admin UI version
display and `docker logs immich-server`.

### Step 1: VectorChord migration — done, verified 2026-08-26

Immich's Docker Compose default already uses VectorChord — boss's
`docker-compose.yml` explicitly pinned the deprecated
`tensorchord/pgvecto-rs:pg14-v0.2.0` image instead, so the migration was
required, not skippable, before any upgrade past v3.0.0 (v3.0.0 drops
pgvecto.rs support entirely).

Steps taken: edited `/opt/immich/docker-compose.yml` — swapped the
`immich-postgres` image to
`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, added
`shm_size: 128mb`, removed the compose-level `healthcheck:` block (the new
image ships its own — confirmed working). `docker compose up -d` completed
cleanly: `clip_index` (28,102 rows) and `face_index` (33,494 rows)
reindexed in ~12 seconds, old `pgvecto.rs` extension dropped, migrations
ran with **no schema drift detected**. User verified the UI (Admin panel +
all user accounts) working normally afterward.

**Survived a full host reboot** of boss (2026-08-26, pending kernel update
applied) — all containers, including `immich-postgres` and
`immich-server`, came back `healthy` on their own after ~4-5 minutes. This
is a stronger validation than the initial `docker compose up -d` alone,
since it confirms the migrated config is durable across a cold restart.
(Nextcloud's web UI took an extra minute or two to become responsive after
its containers reported `healthy` post-reboot — plausibly explained by
Docker healthchecks only confirming a lightweight internal check, not full
PHP/Apache warm-up, with every container on the host starting cold
simultaneously; not investigated further since it resolved on its own and
isn't part of the Immich upgrade.)

The recurring `pgvecto.rs` IPC-hang bug (documented separately in
`ipc-error-break.md`) has not reappeared since the migration (expected,
since `pgvecto.rs` is no longer in use) — worth continued observation, not
declared permanently resolved.

**Key fact:** `immich-server`/`immich-machine-learning` images are pinned
to the `:release` tag, not `${IMMICH_VERSION}` — there is no `.env`
variable controlling the app version. Steps 3/4 required directly editing
those two image tags to explicit version pins rather than bumping an
environment variable.

A `docker-compose.yml` mirrored in this project directory had been
confirmed byte-for-byte in sync with the live file on boss just before
this edit. Rather than update it to match, it was **deleted** — a stale
local copy of a file that lives on boss is a standing risk of confusion
(it caused exactly that during this session); pasting in actual current
contents when needed is preferred over keeping a copy that can silently
drift.

### Step 2: backup checkpoint — done, verified 2026-08-27

Waited on the existing nightly 02:00 scheduled DB dump rather than a
one-off manual `pg_dump` — no urgency, and sticking to the
established/trusted backup mechanism was the preferred call (no manual
"run now" trigger exists in this API version — confirmed via the server's
own route-mapping log output: `DatabaseBackupController` only exposes
`GET`/`DELETE`/`start-restore`/`upload`, no `POST` to trigger a new dump on
demand). The 2026-08-27 nightly dump landed as
`immich-db-backup-20260827T020000-v2.7.5-pg14.19.sql.gz` — its Postgres
point-version tag changed from `pg14.17` (all prior dumps) to `pg14.19`,
independently confirming the scheduled backup ran successfully against the
migrated database.

### Step 3: v3.0.3 — done, verified 2026-08-27

Image tags on `immich-server`/`immich-machine-learning` edited to explicit
`:v3.0.3` tags. Came up clean: 17 DB migrations succeeded (including
`MigrateAlbumOwnerIdToAlbumUser`, `DropDeviceIdAndDeviceAssetId`), no
schema drift, both accounts verified working in the UI.

**Side incident (2026-08-28, resolved, unrelated to the upgrade itself):**
after this upgrade, both mobile apps (silently stuck on the old v2.7.5
client for months, confirmed via the `session` table's
`appVersion`/`updatedAt` columns — more reliable than reconstructing
history from F-Droid) stopped backing up. Updating the mobile apps to
v3.1.0 didn't fix it. Investigation initially suspected a client/server
major-version mismatch (Immich's docs say mobile should be upgraded
before the server, and v2.7.5-mobile-against-v3.0.3-server was briefly a
real condition), and separately turned up two unrelated pre-existing
corrupted JPEGs (`20120310_141449.jpg`, `SAM_1001.jpg`, both from
mid-August, both in Rod's own library — flagged for later, not blocking).
**Actual root cause**, found via the mobile app's own local log file: the
server URL had been mistyped as `http://photos.advappsw.com` instead of
`https://` when re-entering credentials on both phones during the app
update — causing connection resets mid-upload (`ProtocolException:
unexpected end of stream`). Not editable from Settings once set; required
a full logout/login with the corrected URL on each phone. Nothing about
the VectorChord migration or v3.0.3 upgrade itself was implicated.

### Step 4: v3.1.0 — done, verified 2026-08-28

Same image-tag edit pattern as step 3 (`:v3.0.3` → `:v3.1.0` on
`immich-server` and `immich-machine-learning`). `docker compose up -d`
came up healthy; UI confirmed on v3.1.0; mobile upload confirmed working
(after the unrelated `http://` URL fix above).

`CLAUDE.md`'s "Stack" heading was updated to reflect v3.1.0 as the new
baseline.
