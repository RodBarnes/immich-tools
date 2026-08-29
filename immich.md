# Immich Import — Reference Guide

How this project's Google Photos + `bard` NAS content was consolidated into
Immich. Kept as a reference in case a similar migration needs to be repeated
or explained to someone else. For current project status, see `STATE.md`;
for design rationale on the EXIF-prep tooling, see `DESIGN.md`.

## Overview

- Sources: Google Photos (`rodlbarnes@gmail.com`, `karenhubbellbarnes@gmail.com`)
  and `bard` (NAS, ~120GB).
- Both Google accounts' full libraries were downloaded and imported into
  their respective Immich accounts. `bard` content went through an
  EXIF-preparation pass (see `DESIGN.md`) before import, since much of it
  lacked usable date metadata.
- Credentials (Immich API keys per account) are stored in Keeper, under the
  "karen" and "rod" login entries, alongside each account's user UUID.

## Preparation

A staging area was created at `/mnt/data/staging` with subdirectories
`bard/`, `rwgps/`, `google-karen/`, `google-rod/`, symlinked at `~/tmp/staging`
on `boss`. All import work happened on `boss` under `~/tmp`. (This staging
area has since been deleted — everything staged was imported. Recreate if a
new import batch is needed.)

Two windows/terminals are useful during an import session:
- A terminal to `boss` (`~/tmp`) for copying photos from staging to the
  import area, running the import script, and cleaning up staging afterward.
- A Nemo file manager window with a WebDAV connection to `/Nextcloud/Photos`
  and an SSH connection to `boss:~/tmp`, for moving non-Immich-appropriate
  images to Nextcloud (see below).

## Downloading from Google Photos

1. Open Google Photos.
2. In the search bar, type the year.
3. Click the first photo.
4. Scroll to the bottom (may take several trips to get there).
5. Hold shift and click the last photo.
6. Click the menu at the upper-left and select download.

## Generating an Immich API key

1. Open Immich.
2. Click the avatar in the upper-right.
3. Click "Account Settings".
4. Click "API Keys" > "New API Key".
5. Enter a descriptive name for the key.
6. Select permissions — generally "Select All".
7. Click "Create" and copy the key value immediately; it isn't shown again.

Verify a key works:
```
curl -s -o /dev/null -w "%{http_code}" -H "x-api-key: $KEY" http://192.168.0.19:2283/api/users/me
```
Get key/account info:
```
curl -s -H "x-api-key: $KEY" http://192.168.0.19:2283/api/users/me | python3 -m json.tool
```

## Import process

1. Copy a batch from staging to the import area, e.g. `cp -r staging/<source>/<YYYY> ~/tmp/immich/`.
2. For `bard` content, run the EXIF-prep pipeline first (`exif-classify.sh`
   report pass, then `exif-photos.sh report`/`update`) — see the exif-tools
   `DESIGN.md`/`README.md` for the full workflow. Google Photos content
   generally didn't need this step.
3. Run `import.sh <full_path> [album_name]` (current version — see this
   project's own `import.sh`; it reads the API key from a `.env` file next
   to the script and defaults the album name to the source directory's
   basename).
4. Review in Immich and confirm everything looks correct. Thumbnail
   generation can lag behind the import.
5. Photos not tied to a specific memory/event (art, web images, reference
   collections) are moved to Nextcloud Photos instead of staying in Immich —
   see below.
6. Remove the batch from the import area, repeat for the next batch.

**Photos with unresolved dates:** rather than blocking import on resolving
every date/structure edge case, the practical approach taken was to import
as-is and add anything with an unresolved or uncertain date to a dedicated
"Attention!" album in Immich, for later review and correction.

**Recreating a Google Photos album in Immich after the fact:** use
`create-album.sh <zip_file> <album_name>` — see this project's `DESIGN.md`
for how it resolves a per-album Google Takeout export's filenames against
already-imported Immich assets.

### Moving images to Nextcloud instead of Immich

If a photo isn't related to a memory or event — it's just an image from the
web, or a collection of photos without a meaningful date/location — it
belongs in Nextcloud Photos, not Immich.

1. Locate the photo(s) in Immich that should be moved and note the
   filename(s).
2. Locate the file(s) in the Nemo window connected to `boss:~/tmp` (under
   its `immich/YYYY` directory) and move them to the Nemo window connected
   to Nextcloud/Photos.
3. Delete the photos from Immich via the UI.
4. Alternatively: download the image from Immich, move it to Nextcloud, then
   delete it from Immich.

### Fixing Where/When

For post-dated pictures, locate another photo from the same event: if
found, click its map pin, then click the location field on the photo being
fixed and paste in the coordinates. If no other photo from the event exists,
use Google Maps to find the address/location, right-click it to copy
coordinates, and paste them into the photo being fixed.

#### Known home locations

| Location    | Coordinates                            |
|-------------|-----------------------------------------|
| 7450 162nd  | 45.46598097321441, -122.84320761790809 |
| Dads Lane   | 48.10860842358163, -117.21680493702837 |
| Columbus    | 44.60308080619685, -123.0854119010686  |
| 24th Albany | 44.61872944952847, -123.09471170449852 |
| Buckeye     | 33.39831144862295, -112.63822624410119 |
| Aloha       | 45.51032402478963, -122.89151702896845 |
| 30th Albany | 44.6135521088461, -123.08688178417495  |
| 5th Fallon  | 39.46971371820306, -118.7868003213364  |
| Port Temple | 45.42534865448381, -122.74224340834934 |

## Verifying / counting a library

Count assets for a given user (get the UUID from the "get key/account info"
call above):
```
docker exec immich-postgres psql -U immich -d immich -c "SELECT COUNT(*) FROM asset WHERE \"ownerId\" = '<UUID>';"
```

## Cleaning up photos imported to the wrong account

If a batch lands in the wrong Immich account (identify the affected assets
by `createdAt` upload-time window and `ownerId` — see `STATE.md`'s Key
Technical Learnings for why `createdAt`-only matching can be unreliable and
what to use instead):

Get the affected count:
```
docker exec immich-postgres psql -U immich -d immich -c "SELECT COUNT(*) FROM asset WHERE \"createdAt\" >= '<date>' AND \"ownerId\" = '<wrong_user_uuid>';"
```
Validate the date range looks right:
```
docker exec immich-postgres psql -U immich -d immich -c "SELECT MIN(\"fileCreatedAt\"), MAX(\"fileCreatedAt\") FROM asset WHERE \"createdAt\" >= '<date>' AND \"ownerId\" = '<wrong_user_uuid>';"
```
Export the affected asset IDs:
```
docker exec immich-postgres psql -U immich -d immich -t -A -c "SELECT id FROM asset WHERE \"createdAt\" >= '<date>' AND \"ownerId\" = '<wrong_user_uuid>';" > /tmp/wrong_account_asset_ids.txt
wc -l /tmp/wrong_account_asset_ids.txt   # sanity-check the count
```
Move them to trash, in batches of 100 (the `DELETE /api/assets` API moves to
trash, it does not purge):
```bash
batch=()
count=0
total=0

while IFS= read -r id; do
    batch+=("\"$id\"")
    (( count++ ))
    if (( count == 100 )); then
        payload="{\"ids\":[$(IFS=,; echo "${batch[*]}")]}"
        curl -s -X DELETE "http://192.168.0.19:2283/api/assets" \
            -H "x-api-key: $KEY" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null
        (( total += count ))
        echo "Deleted $total so far..."
        batch=()
        count=0
    fi
done < /tmp/wrong_account_asset_ids.txt

if (( count > 0 )); then
    payload="{\"ids\":[$(IFS=,; echo "${batch[*]}")]}"
    curl -s -X DELETE "http://192.168.0.19:2283/api/assets" \
        -H "x-api-key: $KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null
    (( total += count ))
    echo "Deleted $total so far..."
fi

echo "Done. Total deleted: $total"
```
Empty the trash only once the cleanup is fully confirmed resolved.
