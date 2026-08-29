# Immich Project — Working Context

## Access
- Immich runs on host `boss`, deployed via Docker Compose at `/opt/immich` on that host.
- Claude has NO direct shell/SSH/docker access to `boss` from this session. Never attempt to run docker/ssh commands directly — instead, provide the exact commands for the user to run on `boss` and wait for the output to be pasted back.
- `docker-ps` is the user's shell alias for `docker ps` on boss.

See `STATE.md` for current infrastructure details, known gotchas, and import
workflow — this file is intentionally limited to behavioral constraints on
how Claude operates in this project, not project facts.
