# `import.sh` — Immich CLI Wrapper

## State

Done/stable — established mechanism, in active use for every batch import
in this project.

## Design

Thin wrapper around `docker run ghcr.io/immich-app/immich-cli:latest
upload --recursive`, mounting a local batch directory read-only into the
container.

### Interface

`import.sh <source_path> [album_name]`.

- `source_path` **must be absolute** — Docker's `-v` bind-mount flag
  interprets any relative path as a *named volume* instead of a host path
  (see `topics/immich-internals.md` for the two distinct silent-failure
  modes this causes). There is no validation in the script for this —
  passing a relative path fails silently or with a misleading error.
- `album_name` defaults to `basename "$source_path"` when omitted. The
  Immich CLI's `--album-name` flag both creates the album if missing and
  adds every uploaded asset to it — relied on deliberately for folders
  where per-photo manual date/location review is needed (import straight
  into a review album, review in the Immich UI, rather than locating
  photos after the fact). See `Collections/Navy Years/` in
  `topics/family-folder-import.md` for the validated example of this
  pattern.

### Credential handling (redesigned 2026-08-08)

Precedence: `.env` file next to the script (`$(dirname "$0")/.env`,
containing `IMMICH_API_KEY=<key>`) → interactive `read -s` prompt as
fallback. Lookup is script-directory-relative, not cwd-relative, so
behavior is consistent regardless of invocation location. This `.env` is
distinct from `/opt/immich/.env` (Immich's own `SECRET_KEY`/
`IMMICH_SECRET`, internal service-to-service auth only). Rejected
alternative: passing the key as a CLI argument — works, but leaves it in
shell history and briefly visible in `ps` output; the `.env` approach
avoids both. Recommended: `chmod 600 .env` since it holds a live
credential in plaintext.

### Workflow (established)

Per batch: `cp -r staging/<source>/<YYYY> ~/tmp/immich/`, run `import.sh`,
verify in the Immich UI, clear `~/tmp/immich/*`, repeat.

- Flattening subdirectory structure when copying into the import area is
  fine — Immich derives dates from EXIF, not directory layout, and the CLI
  walks recursively regardless of depth.
- Re-running an import with an already-imported batch reports everything
  as "Skipped" rather than erroring.
- Images not tied to a specific memory/event (art, web images, reference
  collections) are moved to Nextcloud Photos instead of staying in Immich
  — moved via Nemo/WebDAV+SSH, then deleted from Immich after confirming
  the copy.
