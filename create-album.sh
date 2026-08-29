#!/bin/bash
# create-album.sh — resolve filenames from a Google Takeout zip (scoped to one
# album) against assets already in Immich, then create/populate an Immich
# album with them.
#
# Usage: create-album.sh [-o|--override] <zip_file> <album_name>
#
# "Not found" and "needs review" results are NOT errors — they can mean the
# photo was intentionally moved to Nextcloud instead of staying in Immich,
# was removed by Immich's own Duplicate Detection (with a surviving copy
# under a different filename), or Google's Takeout export renamed it with a
# "(1)"/"(2)" suffix that doesn't match what's stored in Immich. Review the
# logged lists manually; the script never guesses.

OVERRIDE=false
if [[ "$1" == "-o" || "$1" == "--override" ]]; then
    OVERRIDE=true
    shift
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [-o|--override] <zip_file> <album_name>"
    exit 1
fi

ZIP_FILE="$1"
ALBUM_NAME="$2"

if [[ ! -f "$ZIP_FILE" ]]; then
    echo "Error: zip file '$ZIP_FILE' does not exist"
    exit 1
fi

SCRIPT_DIR="$(dirname "$0")"
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

if [[ -z "$IMMICH_API_KEY" ]]; then
    read -s -p "Immich API key: " KEY
    echo
else
    KEY="$IMMICH_API_KEY"
fi

IMMICH_INSTANCE_URL="${IMMICH_INSTANCE_URL:-http://192.168.0.19:2283/api}"

# api <method> <path> [json_body]
# Prints response body on 2xx; prints an error and exits non-zero otherwise.
api() {
    local method="$1" path="$2" body="$3" resp status
    if [[ -n "$body" ]]; then
        resp=$(curl -sS -w '\n%{http_code}' -X "$method" "$IMMICH_INSTANCE_URL$path" \
            -H "x-api-key: $KEY" -H "Content-Type: application/json" -d "$body")
    else
        resp=$(curl -sS -w '\n%{http_code}' -X "$method" "$IMMICH_INSTANCE_URL$path" \
            -H "x-api-key: $KEY")
    fi
    status="${resp##*$'\n'}"
    body_out="${resp%$'\n'*}"
    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
        echo "Error: $method $path returned HTTP $status: $body_out" >&2
        exit 1
    fi
    echo "$body_out"
}

# Media extensions worth resolving — photos AND video (Motion Photos pair a
# JPG with an MP4), excluding Takeout's .json sidecar files.
MEDIA_EXT_REGEX='\.(jpg|jpeg|png|heic|heif|gif|webp|tif|tiff|bmp|mp4|mov|avi|mkv|3gp|m4v)$'

mapfile -t FILENAMES < <(
    unzip -Z1 "$ZIP_FILE" \
        | grep -viE '\.json$' \
        | grep -iE "$MEDIA_EXT_REGEX" \
        | xargs -n1 basename \
        | sort -u
)

if [[ ${#FILENAMES[@]} -eq 0 ]]; then
    echo "No media files found in $ZIP_FILE"
    exit 1
fi

echo "Found ${#FILENAMES[@]} candidate media filenames in $ZIP_FILE"

RESOLVED_IDS=()
NOT_FOUND=()
NEEDS_REVIEW=()

for fname in "${FILENAMES[@]}"; do
    esc_fname=$(FNAME="$fname" python3 -c 'import json,os; print(json.dumps(os.environ["FNAME"]))')
    response=$(api POST "/search/metadata" "{\"originalFileName\": $esc_fname}")

    count=$(RESP="$response" python3 -c 'import json,os; d=json.loads(os.environ["RESP"]); print(len(d["assets"]["items"]))')

    if [[ "$count" -eq 1 ]]; then
        id=$(RESP="$response" python3 -c 'import json,os; d=json.loads(os.environ["RESP"]); print(d["assets"]["items"][0]["id"])')
        RESOLVED_IDS+=("$id")
    elif [[ "$count" -eq 0 ]]; then
        NOT_FOUND+=("$fname")
    else
        NEEDS_REVIEW+=("$fname")
    fi
done

echo "Resolved: ${#RESOLVED_IDS[@]}   Not found: ${#NOT_FOUND[@]}   Needs review (multiple matches): ${#NEEDS_REVIEW[@]}"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
SAFE_ALBUM_NAME=$(echo "$ALBUM_NAME" | tr -c '[:alnum:]_-' '_')
LOG_PREFIX="$LOG_DIR/${SAFE_ALBUM_NAME}-${TIMESTAMP}"

if [[ ${#NOT_FOUND[@]} -gt 0 ]]; then
    printf '%s\n' "${NOT_FOUND[@]}" > "${LOG_PREFIX}-not-found.txt"
    echo "Not-found list: ${LOG_PREFIX}-not-found.txt"
fi

if [[ ${#NEEDS_REVIEW[@]} -gt 0 ]]; then
    printf '%s\n' "${NEEDS_REVIEW[@]}" > "${LOG_PREFIX}-needs-review.txt"
    echo "Needs-review list: ${LOG_PREFIX}-needs-review.txt"
fi

if [[ ${#RESOLVED_IDS[@]} -eq 0 ]]; then
    echo "No assets resolved — nothing to add to an album."
    exit 0
fi

albums_response=$(api GET "/albums" "")
existing_id=$(RESP="$albums_response" NAME="$ALBUM_NAME" python3 -c '
import json, os
albums = json.loads(os.environ["RESP"])
name = os.environ["NAME"]
matches = [a["id"] for a in albums if a.get("albumName") == name]
print(matches[0] if len(matches) == 1 else ("MULTIPLE" if len(matches) > 1 else ""))
')

if [[ "$existing_id" == "MULTIPLE" ]]; then
    echo "Error: multiple existing albums named '$ALBUM_NAME' — resolve manually before proceeding."
    exit 1
fi

if [[ -n "$existing_id" ]]; then
    if [[ "$OVERRIDE" != true ]]; then
        echo "Error: an album named '$ALBUM_NAME' already exists (id: $existing_id)."
        echo "Use -o/--override to add the resolved assets to it instead."
        exit 1
    fi
    echo "Adding ${#RESOLVED_IDS[@]} assets to existing album '$ALBUM_NAME' (id: $existing_id)..."
    ids_json=$(printf '%s\n' "${RESOLVED_IDS[@]}" | python3 -c 'import json,sys; print(json.dumps({"ids":[l.strip() for l in sys.stdin if l.strip()]}))')
    api PUT "/albums/$existing_id/assets" "$ids_json" > /dev/null
    echo "Done."
else
    echo "Creating new album '$ALBUM_NAME' with ${#RESOLVED_IDS[@]} assets..."
    body=$(printf '%s\n' "${RESOLVED_IDS[@]} " | NAME="$ALBUM_NAME" python3 -c '
import json, os, sys
ids = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps({"albumName": os.environ["NAME"], "assetIds": ids}))
')
    api POST "/albums" "$body" > /dev/null
    echo "Done."
fi
