# Immich Migration — Project Index

_Last updated: 2026-09-01_

This file is the entry point for a new session: a short project overview,
the current infrastructure facts, and an index of topic docs under
`topics/`. Each topic doc carries its own state (where things stand) and,
where an actual artifact resulted from it (code, config, a policy), its own
design section. Durable technical facts that aren't tied to one topic live
in `topics/immich-internals.md`.

`DESIGN.md` no longer exists — there was no single overall architecture
here, only per-tool/per-topic decisions, so its content was redistributed
into the relevant topic docs above.

## Project goal

Consolidate all photos from multiple sources into a single self-hosted
Immich instance on `boss`, replacing Google Photos entirely:

- Rod's Google Photos (`rodlbarnes@gmail.com`)
- Karen's Google Photos (`karenhubbellbarnes@gmail.com`)
- ~120GB of photos on `bard` (NAS/file server, formerly named `media`,
  renamed to resolve a naming conflict)

## Repository conventions

All scripts and design/status docs live in one repo (`immich-tools` on
GitHub, `~/src/mine/immich-tools` locally — formerly `exif-tools`, renamed
2026-08-29 and merged with the separate Nextcloud-based `immich` project
once scope grew beyond EXIF-only prep). Photo data itself (`staging/`, and
any `.env` holding a live Immich API key) never lives in this repo — it
stays on `boss` or wherever it's actively being worked, excluded via
`.gitignore`.

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
  imported. No staging area currently exists; recreate if a new import
  batch is needed.
- Postgres DB: `/mnt/data/immich/postgres`, container `immich-postgres`,
  table `asset` (see `topics/immich-internals.md` for schema detail)
- Rod's Immich user UUID: `cf0d38b8-611f-483c-a889-38ec7029909d`
- Karen's Immich user UUID: `6c7abd53-aac9-43fa-a607-ac3f3e205d2d`
- Full container list: `immich-server`, `immich-postgres`, `immich-redis`,
  `immich-machine-learning`.
- DB credentials lookup (on boss): `sudo grep -E "^DB_USERNAME|^DB_DATABASE_NAME" /opt/immich/.env`
  (root-owned; needs `sudo` to read — see `topics/immich-internals.md` for
  the `docker exec ... -U/-d` pattern this feeds)
- Current stack version: **v3.1.0** (see `topics/immich-server-upgrade.md`)

## Topic index

| Topic | Status | Doc |
|---|---|---|
| Timezone correction for already-imported photos | active | `topics/timezone-correction.md` |
| Album naming/organization policy (year via grouping, not name) | done | `topics/album-naming-policy.md` |
| `Family/` named-folder import pass | active (current focus) | `topics/family-folder-import.md` |
| Karen/Rod cross-account mis-import correction | active, stalled on count verification | `topics/karen-rod-misimport.md` |
| "Imported" album shows 0 items | parked since 2026-08-08 | `topics/imported-album-zero-items.md` |
| `exif-classify.sh`/`exif-photos.sh`/`find-duplicates.sh` pipeline | done/stable | `topics/exif-tools-pipeline.md` |
| `import.sh` | done/stable | `topics/import-sh.md` |
| `create-album.sh` | done, one open sub-idea (album recreation workflow) | `topics/create-album-sh.md` |
| Immich server upgrade v2.7.5 → v3.1.0 | done | `topics/immich-server-upgrade.md` |
| Immich/Docker/Postgres technical reference | reference, not a topic | `topics/immich-internals.md` |

## Other open items (small enough not to warrant their own topic doc yet)

- **Merge-vs-separate decision:** whether to merge all EXIF-era sources
  into a single area or keep them separate once everything is imported —
  not yet decided.
- **Second-pass analysis phase** planned after all EXIF-era photos are in
  Immich — not yet scoped.
- **Immich album sort order is hardcoded to "Newest first"** — no fix
  expected near-term (tracked upstream as GitHub discussion #1689);
  Nextcloud is used as an interim holding area for manually-ordered
  categorical albums.

## Recent administrative history

- **README.md rewrite (2026-08-28):** was still titled/scoped as
  `exif-tools`, documented only `exif-classify.sh`/`exif-photos.sh`. Now
  describes all five tools in pipeline order (dedup → classify → EXIF
  fill → upload → album recreation).
- **Repo consolidation (2026-08-29):** renamed `exif-tools` → `immich-tools`
  (GitHub and local), merged with the separate Nextcloud-based `immich`
  project (`~/Nextcloud/claude/immich`, not a git repo). `immich.md`/
  `notes.md` reconciled into one `immich.md` reference guide; `PROCESS.md`
  deleted (redundant with this file's Open Items). The old
  `~/Nextcloud/claude/immich` directory is retired — this repo is the sole
  surviving location for this project's code and docs.
- **Docs restructure (2026-09-01):** split this file and the former
  `DESIGN.md` into the `topics/` structure described above, to keep each
  discussion findable on its own rather than buried in one growing log.
