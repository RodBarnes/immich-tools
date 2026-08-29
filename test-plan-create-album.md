# Test Plan — `create-album.sh`

Manual test plan for `create-album.sh`, covering every branch in the
script's logic (see `DESIGN.md` for the design rationale). Run against the
Immich instance's LAN address, not the external one, per the script's
default.

Requires a test zip (or several) of Google Takeout-style content — no
extraction needed, the script reads the zip's directory listing directly.
Filenames should be photos **already known to be imported into Immich**
under the account whose API key is being used, so match/no-match outcomes
are predictable ahead of time.

## Setup

- Build one small zip with a handful of files (`unzip -Z1` should list
  them) named after real filenames already in Immich, e.g. by zipping a
  copy of 3-5 files from a folder you know was imported.
- Have the API key for that same account in `.env` next to the script (or
  ready to paste at the interactive prompt).
- Pick an album name that does **not** already exist in Immich, to start
  from a clean state for the create-path tests.

## Cases

1. **Happy path — new album, all resolved.**
   Zip contains only filenames that exist exactly once in Immich.
   Run: `./create-album.sh test.zip "Test Album 1"`.
   Expect: "Resolved: N   Not found: 0   Needs review: 0", new album
   created via `POST /api/albums`, all N assets in it (verify in Immich
   UI). No `-not-found.txt`/`-needs-review.txt` log files written.

2. **Not-found filename.**
   Add one filename to the zip that is *not* in Immich (e.g. a made-up
   name with a valid extension).
   Expect: that file counted under "Not found", written to
   `logs/<album>-<timestamp>-not-found.txt`, script continues and still
   creates the album with the remaining resolved assets — not-found is
   not treated as an error.

3. **Multiple matches (needs review).**
   Requires a filename that resolves to more than one asset in the test
   account (e.g. genuinely duplicate filenames, if any exist; otherwise
   this case may need to be verified by reading the code path rather than
   reproduced against real data).
   Expect: filename counted under "Needs review", written to
   `logs/<album>-<timestamp>-needs-review.txt`, excluded from the album's
   asset list, not auto-picked.

4. **Existing album, no `-o`.**
   Re-run case 1's command again (album now exists from the first run).
   Expect: `Error: an album named '...' already exists`, script exits
   non-zero, **no** `PUT`/`POST` call made — verify the album's asset
   count in Immich is unchanged.

5. **Existing album, with `-o`/`--override`.**
   Re-run with `-o`: `./create-album.sh -o test.zip "Test Album 1"`, this
   time with a zip containing at least one *additional* known-good
   filename not in the original set.
   Expect: `PUT /api/albums/{id}/assets` called, new asset(s) added
   without duplicating the ones already there, script reports "Adding N
   assets to existing album".

6. **Multiple existing albums with the same name.**
   Manually create a second album with the exact same name via the
   Immich UI, then run the script against that name.
   Expect: `Error: multiple existing albums named '...' — resolve
   manually`, exits non-zero, no API mutation attempted. Clean up the
   duplicate album afterward.

7. **Zero resolved assets.**
   Zip containing only not-found/needs-review filenames, no clean single
   match.
   Expect: "No assets resolved — nothing to add to an album.", exits 0,
   no album created or modified, not-found/needs-review logs still
   written.

8. **Non-media / sidecar filtering.**
   Zip containing a `.json` sidecar and a non-media extension (e.g.
   `.txt`) alongside real photos.
   Expect: those files never appear in the candidate filename count or in
   any log file — confirm via the "Found N candidate media filenames"
   line matching only the real media count.

9. **Usage/argument errors.**
   Run with no args, one arg, and a nonexistent zip path.
   Expect: usage message and non-zero exit for missing args; "Error: zip
   file '...' does not exist" for a bad path. No network calls made in
   either case.

10. **Cross-account scoping regression check.**
    (Already confirmed once during development — DESIGN.md notes this was
    verified via a deliberate cross-account test.) Re-verify only if the
    search/API logic changes: upload the same filename to two different
    accounts, confirm `create-album.sh` run with one account's key never
    resolves the other account's asset.

## Cleanup

Delete any test albums (`Test Album 1`, the duplicate-name album from
case 6) from the Immich UI after the run. Log files under
`logs/*-not-found.txt` / `logs/*-needs-review.txt` are harmless to leave
or delete.
