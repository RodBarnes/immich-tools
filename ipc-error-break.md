# Incident: Missing Thumbnails/Videos After Import — pgvecto.rs IPC Errors + Undispatched Job Backlog

_Date of incident: 2026-08-16, evening._
_Investigated: 2026-08-16, on `boss`._
_Immich version: 3.1.0 (server container recreated earlier same day per `search-failure.md`)._
_Status: SYMPTOMS RESOLVED, ROOT CAUSE NOT IDENTIFIED. All visible symptoms (missing thumbnails, unplayable videos, assets absent from timeline, squished JPGs) are confirmed fixed as of 2026-08-16 ~22:22 local, by manually draining job backlogs across multiple job types. The underlying question of why automatic job dispatch on upload isn't happening in this deployment remains open and is the priority for the next session. See "Final status" section near the bottom._

## Symptom

Four albums were created from four separate import passes (24 files total: 12 AVI, 2 MPG, 10 JPG). All four:
- Showed no album-level thumbnail.
- Contained individual assets with no thumbnail.
- Contained videos stuck showing a "still processing" spinner, some with a red warning icon on hover.
- None of the assets from these four albums appeared in the main timeline at all (noticed partway through investigation; not yet resolved).
- Two JPGs, once thumbnails did generate, displayed with an incorrect/squished aspect ratio (noticed later; not yet resolved).

The server otherwise appeared to respond normally (other existing photos/videos viewable).

## Investigation timeline

1. **Administration → Jobs panel initially showed 0 Active / 0 Waiting on every job type.** This ruled out "server busy/backlogged" as the explanation — an idle queue can't be why new assets aren't processed.
2. **Failed counts were nonzero** on Smart Search (6), OCR (4), Facial Recognition (8); Transcode Videos and Generate Thumbnails showed 0 Failed at that point.
3. Clicked **Missing** on Generate Thumbnails → 1 failure. Log grep showed a genuine, unrelated cause: `VipsJpeg: premature end of JPEG image` for asset `e73bce04-fbd7-4ac4-923f-3ac64371cfd5` — a truncated/corrupt JPEG file, not a server problem.
4. The same log pull surfaced a recurring, more serious error unrelated to that JPEG:
   ```
   PostgresError: pgvecto.rs: IPC connection is closed unexpected.
   ADVICE: The error is raisen by background worker errors...
   ```
   occurring repeatedly across many different queries — not just vector/embedding inserts (`smart_search`, `face_search`) but also plain unrelated queries (e.g. a basic admin-user lookup) — each timing out at ~15 seconds before failing.
5. `docker ps` showed `immich-postgres` reporting "healthy" throughout. `docker logs immich-postgres` was useless (only shows startup banners; last real line was from 2026-06-20) because Postgres redirects to file-based logging (documented gotcha, see `CLAUDE.md`).
6. Found the real Postgres logs inside the container at `/var/lib/postgresql/data/log/`. Two files existed for 2026-08-16: a 10.4MB one from earlier in the day (bloated because `log_statement` had been left at `'all'` since the `search-failure.md` session and never reverted) and a smaller one starting at the `--force-recreate` restart from that same earlier session.
7. Grepped both files for `vecto|background worker|PANIC|FATAL|WARNING`. Found the IPC error recurring every ~10-20 seconds from **21:36:20 UTC to 21:56:15 UTC** (~20 minutes), then it stopped on its own. No PANIC/FATAL log entry ever explained *why* the background worker's IPC channel broke — Postgres only ever logs the symptom.
8. Checked for OOM: `sudo dmesg -T | grep -i -E "kill|oom"` returned nothing. `free -h` showed healthy headroom (11GB available of 15GB). OOM-kill was ruled out as the visible cause, at least within the current dmesg ring buffer.
9. **Reverted `log_statement` from `'all'` back to `'none'`** (leftover from the earlier session — this should have been reverted then; now documented as a known gotcha). Note: `ALTER SYSTEM` cannot be combined with a second statement in one `psql -c` call (fails with "cannot run inside a transaction block") — must be run as two separate `-c` invocations.
10. Retried **Missing** on Generate Thumbnails after the pgvecto.rs window had closed → completed clean.
11. Retried **Missing** on Transcode Videos → revealed **1,012 waiting videos**, far more than the 24-file import batch could account for. Confirmed (per user recollection) that video auto-encoding had always worked on every prior import — this was the first time it broke. The pre-existing 0/0/0 job counts (not a backed-up queue) indicate these jobs were never enqueued in the first place, not that they were queued and stuck. Backlog drained fully with **0 failures**.
12. Re-checked the four albums: still no album thumbnails; per-asset state was a mix of playable, missing-thumbnail, and perpetually-spinning ("stuck encoding") assets — see the per-album breakdown in the conversation log. None of this is explained by the pgvecto.rs window or the video backlog drain. **Still open.**
13. Restarted `immich-server` (`docker restart immich-server`) — came back healthy. Did not resolve the timeline/squished-JPG symptoms (not re-verified in detail afterward; deferred).
14. Continued sweeping **Missing** across the remaining job types. **Sidecar Metadata showed ~20,000 waiting** — orders of magnitude beyond this import batch, confirming job dispatch had been broken/backlogged across a large portion of the library for an unknown period of time, not something newly caused by this session's import.
15. During the backlog drain, `docker stats` showed `immich-server` at ~299% CPU (~3 of 4 cores), `immich-postgres` ~45%, `immich-machine-learning` nearly idle. `uptime` showed load average 4.75 on a 4-core host (`nproc` = 4) — genuine, proportionate CPU saturation from legitimately working through a large backlog, not a hang. This answered the original triggering question ("is the server overloaded") for that moment — yes, but as a *consequence* of draining the newly-discovered backlog, not as the *cause* of the original missing-thumbnail symptoms (which occurred while the queues were empty).
16. Sidecar Metadata finished. Smart Search (59 waiting) proceeded slowly even with `docker stats` showing near-idle CPU across all containers — determined to be expected: Smart Search does one CLIP inference at a time (low configured concurrency), not resource-constrained. It does inference only (no training/learning from the library).
17. Smart Search later stalled at Active 2 / Waiting 1, unchanged after a browser refresh. `docker stats` showed `immich-machine-learning` at 0.18% CPU with reduced memory (suggesting the model had unloaded/gone idle) and `immich-postgres` at 8.81% — indicating a hang, not slow progress.
18. `docker logs immich-server` and the Postgres log file both confirmed: **the pgvecto.rs IPC error had returned and was recurring continuously** (not just a bounded ~20-minute window this time), and it was still happening *after* the earlier `immich-server` restart — proving an app-container restart alone does not fix it. The same fixed set of backend connection PIDs kept failing on every query, including an unrelated `StorageTemplateMigrationSingle` job's plain asset lookup — confirming again that it's connection-level, not query-type-specific.
19. **Restarted `immich-postgres` specifically** (`docker restart immich-postgres`, a plain restart, not `--force-recreate`). All containers back healthy within ~30 seconds. The stalled Smart Search job completed immediately afterward. **This is the confirmed, reproducible fix for the pgvecto.rs hang** — restarting `immich-postgres` clears it; restarting `immich-server` alone does not.
20. Checked one of the 2 Smart Search failures via log grep. Found a distinct, unrelated, one-off cause: `Error: Machine learning repository not been setup` plus several `Template not initialized` errors, timestamped right next to `Finished running migrations` — a startup race condition where a queued job fired before internal services (ML config, storage template) had finished initializing after the `immich-postgres` restart. Expected to resolve cleanly on retry; not a data or pgvecto.rs issue.
21. User is now letting all remaining job types run to completion with Postgres in a clean state; multiple additional backlogs have surfaced across job types now that they're actually able to run.

## What we know (confirmed facts)

- **The pgvecto.rs background worker (inside `immich-postgres`, image `tensorchord/pgvecto-rs:pg14-v0.2.0`) intermittently loses its IPC connection**, causing every query on the affected backend connections to fail after a 15-second timeout — not limited to vector/embedding queries, any query on a broken connection fails. Observed twice in one session: once for a bounded ~20-minute window, once as a continuous/ongoing failure.
- **The only confirmed fix is restarting the `immich-postgres` container itself.** Restarting `immich-server` does not clear it, even though `immich-server` is the container that surfaces the errors in its own logs.
- **A large volume of jobs across multiple types were never auto-dispatched** for a substantial portion of the library, for an unknown period predating this import session (Transcode Videos: 1,012 backlog; Sidecar Metadata: ~20,000 backlog — both vastly larger than the 24-file import batch). The Jobs panel showed 0 Active/0 Waiting for these before manually triggering "Missing," meaning the jobs were never created, not that they were queued and stalled.
- The corrupt-JPEG thumbnail failure and the startup-race-condition Smart Search failure are both one-off, unrelated causes, not systemic — each identified precisely via `docker logs immich-server` grep for `Unable to run job handler`.
- The host was genuinely idle when the problem was first noticed (0/0/0 job queues, no CPU/memory pressure). The later CPU saturation (load average 4.75 on 4 cores) was a direct, proportionate consequence of manually draining the newly-discovered backlog — not evidence of an overloaded host causing the original symptoms.

## What we do NOT know (open questions)

1. **Why does the pgvecto.rs background worker's IPC connection break in the first place?** No OOM-kill evidence in `dmesg`. Postgres logs only ever show the symptom ("IPC connection is closed unexpected"), never a PANIC/FATAL entry explaining a crash. Unresolved.
2. **Why were jobs (at least Transcode Videos and Sidecar Metadata, likely others) not being automatically dispatched on asset creation for a large part of the library, for an unknown period?** This is the central unresolved question, and it is distinct from the pgvecto.rs worker issue — the queues were empty, not backed up, before the issue was noticed. Not yet investigated further (e.g., no attempt yet to find the oldest asset missing a given job's output, which would date when normal dispatch stopped working).
3. **Why do none of the four albums' assets appear in the main timeline?** Not explained by either the pgvecto.rs issue or the job-dispatch backlog. Still open; `immich-server` was restarted since first noticing this but the fix was not re-verified.
4. **Why do 2 JPGs render with a squished/incorrect aspect ratio once thumbnailed?** A distinct, apparently genuine thumbnail-generation defect. Still open.
5. Whether the pgvecto.rs hang will recur, and under what trigger — not yet determined. Worth watching for it again during the current full job sweep.

## Ruled out

- "The server is overloaded/busy" as the original explanation for missing thumbnails — the Jobs panel showed 0/0/0 everywhere at first, i.e. genuinely idle, not backed up.
- "This import overwhelmed the server with too many videos at once" — contradicted by (a) the 24-file batch being far smaller than the 1,012-video and ~20,000-sidecar backlogs found, and (b) every prior import having auto-encoded successfully before this one.

## Useful commands reference

Check for job failures by type (gives asset ID + full error/stack trace):
```
sudo docker logs immich-server --tail 500 2>&1 | grep -B2 -A15 "Unable to run job handler (<JobType>)"
```

Look up an asset's filename from its ID:
```
sudo docker exec -it immich-postgres psql -U immich -d immich -c "SELECT id, \"originalFileName\" FROM asset WHERE id = '<asset-id>';" -P pager=off
```

Check/revert `log_statement` (must be two SEPARATE `-c` calls — `ALTER SYSTEM` cannot run in the same implicit transaction as another statement):
```
sudo docker exec immich-postgres psql -U immich -d immich -c "ALTER SYSTEM SET log_statement = 'none';" -P pager=off
sudo docker exec immich-postgres psql -U immich -d immich -c "SELECT pg_reload_conf();" -P pager=off
sudo docker exec immich-postgres psql -U immich -d immich -c "SHOW log_statement;" -P pager=off
```

List/read the real Postgres log files (not `docker logs`):
```
sudo docker exec immich-postgres bash -c "ls -la /var/lib/postgresql/data/log/ | tail -10"
sudo docker exec immich-postgres bash -c "grep -i 'vecto\|background worker\|PANIC\|FATAL\|WARNING' /var/lib/postgresql/data/log/postgresql-<date>.log | tail -60"
```

Check for OOM-kill events and memory headroom:
```
sudo dmesg -T | grep -i -E "kill|oom"
free -h
```

Check live container resource usage and host load:
```
sudo docker stats --no-stream
uptime
nproc
```

**Fix for the pgvecto.rs IPC hang (confirmed working):**
```
sudo docker restart immich-postgres
```

## Final status (2026-08-16, session paused ~22:22 local)

**All originally-reported symptoms are now confirmed resolved:**
- All four albums show thumbnails.
- All imported videos are transcoded and playable.
- All content from the four albums now appears correctly in the main timeline.
- The two squished-aspect-ratio JPGs now display correctly.

This was reached by working through every one of the twelve job types in Administration → Jobs with "Missing" (or "Discover," see below), one at a time, letting each fully drain, and restarting `immich-postgres` once when the pgvecto.rs worker hung again mid-session.

### Correction: manual job triggering is NOT normal/expected behavior

Partway through this session it was suggested that periodically re-clicking "Missing" across job types might be a reasonable ongoing habit. **That framing was wrong and was corrected during the session.** Immich's standard, documented design is for jobs (thumbnail generation, metadata extraction, video transcoding, etc.) to be dispatched automatically the instant an asset is uploaded — no manual intervention should ever be required for a healthy instance. The fact that this instance required manual "Missing" triggers across nearly every job type to process what turned out to be large real backlogs (Transcode Videos: ~1,200; Sidecar Metadata: ~20,000; Extract Metadata: ~33,000) is itself a defect in this deployment, not routine operation. This is the actual unresolved problem — see "What we do NOT know" above, item 2, now the top priority.

### "Discover" button label — narrower than first assumed

Earlier it was tentatively concluded that "Missing" relabeling to "Discover" after a completed run was general UI behavior across job types ("that appears to be design"). Re-tested at end of session: clicking **Extract Metadata**'s button with a genuine 0/0 backlog and no new imports returned it to 0 instantly and the button stayed/reverted to **"Missing"** — it did NOT show "Discover." So the "Discover" label appears to be specific to **Sidecar Metadata** (and possibly other library/file-scanning-style jobs), not a universal post-completion state for every job type. Not fully characterized — worth confirming which job types show "Discover" vs "Missing" when next investigating.

### Next session priorities

1. **Find out why automatic job dispatch on upload isn't happening.** Proposed test (not yet performed): upload a single small test file through the browser while tailing `sudo docker logs -f immich-server`, to see whether the job-enqueue call fires (and succeeds or errors) at the moment of upload.
2. **Check `immich-redis`** — all Immich job queueing runs through Redis via BullMQ, and this container's logs/health were never examined at all this session (all attention went to `immich-postgres`/pgvecto.rs). Worth checking `sudo docker logs immich-redis` and general Redis health as part of the same investigation.
3. Watch for recurrence of the pgvecto.rs IPC hang, especially under heavy job load (`sudo docker restart immich-postgres` is the confirmed fix if it recurs).
4. Consider periodically re-checking all twelve job types with "Missing" until the root cause above is found and fixed, since new uploads may currently be silently undispatched the same way.
