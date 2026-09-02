#!/bin/bash
# album-photo-metadata.sh
#
# Lists filename/timestamp/timezone/GPS/camera metadata for every photo in a
# given Immich album, as CSV. Runs against the immich-postgres container
# directly (read-only query), so this must be run on the Immich host (boss).
#
# Usage:
#   album-photo-metadata.sh <album_name_or_id> [output_csv]
#
# <album_name_or_id> -- either an album's exact name, or its UUID. Since
#   album names are not unique (see topics/album-naming-policy.md), a name
#   that matches more than one album is treated as ambiguous: the script
#   lists the matching albums (id, description, date range) and exits
#   without querying, so you can re-run with the specific id instead of
#   guessing which one was meant.
#
# [output_csv] -- defaults to <album_name>.csv (spaces/colons replaced with
#   "_") in the current directory if not given.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <album_name_or_id> [output_csv]" >&2
    exit 1
fi

ALBUM_ARG="$1"

# ---------------------------------------------------------------------------
# Resolve ALBUM_ARG to a single album id
# ---------------------------------------------------------------------------
if [[ "$ALBUM_ARG" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    ALBUM_ID="$ALBUM_ARG"
    ALBUM_NAME="$ALBUM_ARG"
else
    MATCHES=$(docker exec immich-postgres psql -U immich -d immich --csv -t -c "
        SELECT id, \"albumName\", description, min(\"createdAt\")::date
        FROM album
        WHERE \"albumName\" = '$(echo "$ALBUM_ARG" | sed "s/'/''/g")'
        GROUP BY id, \"albumName\", description;
    ")

    MATCH_COUNT=$(echo "$MATCHES" | grep -c . || true)

    if [[ "$MATCH_COUNT" -eq 0 ]]; then
        echo "No album found named '$ALBUM_ARG'." >&2
        exit 1
    elif [[ "$MATCH_COUNT" -gt 1 ]]; then
        echo "Ambiguous: $MATCH_COUNT albums named '$ALBUM_ARG'. Re-run with one of these ids instead:" >&2
        echo "$MATCHES" >&2
        exit 1
    fi

    ALBUM_ID=$(echo "$MATCHES" | cut -d',' -f1)
    ALBUM_NAME="$ALBUM_ARG"
fi

OUTPUT_CSV="${2:-$(echo "$ALBUM_NAME" | tr ' :' '__').csv}"

# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------
docker exec immich-postgres psql -U immich -d immich --csv -c "
SELECT
  a.\"originalFileName\" AS filename,
  e.\"dateTimeOriginal\" AS timestamp,
  e.\"timeZone\" AS timezone,
  e.latitude,
  e.longitude,
  e.make,
  e.model
FROM asset a
JOIN asset_exif e ON e.\"assetId\" = a.id
JOIN album_asset aa ON aa.\"assetId\" = a.id
JOIN album al ON al.id = aa.\"albumId\"
WHERE al.id = '$ALBUM_ID'
  AND a.\"deletedAt\" IS NULL
ORDER BY e.\"dateTimeOriginal\";
" > "$OUTPUT_CSV"

echo "Wrote $(($(wc -l < "$OUTPUT_CSV") - 1)) rows to $OUTPUT_CSV"
