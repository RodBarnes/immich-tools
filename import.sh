#!/bin/bash
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <source_path> [album_name]"
    exit 1
fi

SOURCE_PATH="$1"
ALBUM_NAME="${2:-$(basename "$SOURCE_PATH")}"

if [[ ! -d "$SOURCE_PATH" ]]; then
    echo "Error: source path '$SOURCE_PATH' does not exist"
    exit 1
fi

ENV_FILE="$(dirname "$0")/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

if [[ -z "$IMMICH_API_KEY" ]]; then
    read -s -p "Immich API key: " KEY
    echo
else
    KEY="$IMMICH_API_KEY"
fi

# Run import
docker run -it \
  -v "$SOURCE_PATH":/import:ro \
  -e IMMICH_INSTANCE_URL=http://192.168.0.19:2283/api \
  -e IMMICH_API_KEY="$KEY" \
  ghcr.io/immich-app/immich-cli:latest \
  upload --recursive --album-name "$ALBUM_NAME" /import
