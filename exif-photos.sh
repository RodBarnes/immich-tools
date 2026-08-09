#!/bin/bash
# exif-photos.sh
#
# Audits or updates EXIF fields for photos. A YYYY/MM directory structure is
# used when present (both for the date fallback and the description label)
# but is not required — files anywhere under base_dir are processed.
# Processes files missing DateTimeOriginal OR missing Description.
#
# Usage:
#   exif-photos.sh report <base_dir> [logfile]
#   exif-photos.sh update <base_dir> [logfile]
#
# Modes:
#   report  -- Preview what update would do; no changes made
#   update  -- Set missing fields using rules below:
#
# DateTimeOriginal (and CreateDate) derived from, in order:
#   1. Existing EXIF value, if present — left untouched
#   2. Timestamp parsed from filename (YYYYMMDD_HHMMSS, YYYYMMDD, MMDDYYHHMMSS)
#   3. YYYY/MM from directory path (if present anywhere in the path), defaulting
#      to 01 00:00:00
#   4. Standalone 4-digit year in the filename (e.g. "Andrew 1989.jpg"),
#      defaulting to 01/01 — lowest-confidence source, logged distinctly as
#      "filename-year-only" so it can be spot-checked later
#   If none of these yield a date, the file is left untouched and flagged
#   NEEDS REVIEW — no date is ever fabricated.
#
# Description (ImageDescription + XMP-dc:Description) derived from:
#   1. Descriptive immediate subdirectory (the first path component after
#      YYYY/MM if that structure is present, otherwise the file's first
#      path component relative to base_dir)
#   2. Descriptive filename (if not a camera-generated name)
#   3. Both combined as "SubDir - Filename" when both are present
#   Only written for files that have (or received) a DateTimeOriginal — a
#   file with no date source gets no description write either.
#
# Supported file types: jpg, jpeg, png, tif
# Not processed: recognized videos (tallied separately, not a skip), other
# non-media file types (skipped)

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 report|update <base_dir> [logfile]"
    exit 1
fi

MODE="$1"
BASE_DIR="$2"
LOGFILE="${3:-exif_photos_$(date +%Y%m%d_%H%M%S).log}"

if [[ "$MODE" != "report" && "$MODE" != "update" ]]; then
    echo "Error: mode must be 'report' or 'update'"
    exit 1
fi

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Error: base directory '$BASE_DIR' does not exist"
    exit 1
fi

# ---------------------------------------------------------------------------
# Supported photo extensions (all lowercase — run extension lowercaser first)
# ---------------------------------------------------------------------------
PHOTO_EXTS="jpg jpeg png tif"

# ---------------------------------------------------------------------------
# Recognized video extensions (all lowercase)
# Videos are valid Immich assets but have no EXIF fields for this script to
# audit/write, so they're tallied separately, not as a skip.
# ---------------------------------------------------------------------------
VIDEO_EXTS="mp4 mov avi mkv wmv m4v 3gp 3g2 mpg"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "$1" | tee -a "$LOGFILE"
}

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
count_processed=0
count_has_date=0
count_missing=0
count_updated_filename=0
count_updated_dir=0
count_needs_review=0
count_skipped_type=0
count_video=0
count_errors=0
count_desc_written=0
count_desc_skipped=0
count_needs_desc=0
declare -A skipped_type_counts=()

# ---------------------------------------------------------------------------
# Check exiftool is available
# ---------------------------------------------------------------------------
if ! command -v exiftool &>/dev/null; then
    echo "Error: exiftool is not installed. Install with: sudo apt install libimage-exiftool-perl"
    exit 1
fi

log "========================================"
log "exif_photos.sh"
log "Mode     : $MODE"
log "Base dir : $BASE_DIR"
log "Log file : $LOGFILE"
log "Started  : $(date)"
log "========================================"
log ""

# ---------------------------------------------------------------------------
# Helper: check if extension is a supported photo type
# ---------------------------------------------------------------------------
is_photo() {
    local ext="${1,,}"  # lowercase
    for e in $PHOTO_EXTS; do
        [[ "$ext" == "$e" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Helper: check if extension is a recognized video type
# ---------------------------------------------------------------------------
is_video() {
    local ext="${1,,}"
    for e in $VIDEO_EXTS; do
        [[ "$ext" == "$e" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Helper: extract DateTimeOriginal via exiftool
# Returns empty string if not present
# ---------------------------------------------------------------------------
get_exif_date() {
    local file="$1"
    exiftool -s3 -DateTimeOriginal "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: extract existing Description via exiftool
# Checks ImageDescription first, then XMP-dc:Description (mirrors Immich priority)
# Returns empty string if neither is present
# ---------------------------------------------------------------------------
get_exif_desc() {
    local file="$1"
    local val
    val=$(exiftool -s3 -ImageDescription "$file" 2>/dev/null || true)
    if [[ -z "$val" ]]; then
        val=$(exiftool -s3 -XMP-dc:Description "$file" 2>/dev/null || true)
    fi
    echo "$val"
}

# ---------------------------------------------------------------------------
# Helper: attempt to parse date from filename
# Patterns tried in order (most specific first):
#   1. YYYYMMDD_HHMMSS  (e.g. 20141008_135239, anywhere in name)
#   2. YYYYMMDD         (e.g. IMG_20141008, anywhere in name)
#   3. MMDDYYHHMMSS     (e.g. 0304011035, 0304011035a — phone format, whole name)
# Returns exiftool-format date string: YYYY:MM:DD HH:MM:SS  or empty
# ---------------------------------------------------------------------------
parse_date_from_filename() {
    local filename="$1"
    local base
    base=$(basename "$filename")
    base="${base%.*}"  # strip extension

    # Pattern 1: YYYYMMDD_HHMMSS (e.g. 20141008_135239)
    if [[ "$base" =~ ([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
        local y="${BASH_REMATCH[1]}"
        local mo="${BASH_REMATCH[2]}"
        local d="${BASH_REMATCH[3]}"
        local h="${BASH_REMATCH[4]}"
        local mi="${BASH_REMATCH[5]}"
        local s="${BASH_REMATCH[6]}"
        echo "${y}:${mo}:${d} ${h}:${mi}:${s}"
        return
    fi

    # Pattern 2: MMDDYYHHMM — exactly 10 digits, optional trailing letter(s)
    # Must be checked before YYYYMMDD since both match 8+ digit strings
    # e.g. 0304011035a (MM=03 DD=04 YY=01 HH=10 MM=35), 1027121015b
    # Note: no seconds field in this format; SS defaults to 00
    local pat_mmddyyhhmm='^(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([0-9]{2})([01][0-9]|2[0-3])([0-5][0-9])[A-Za-z]*$'
    if [[ "$base" =~ $pat_mmddyyhhmm ]]; then
        local mo="${BASH_REMATCH[1]}"
        local d="${BASH_REMATCH[2]}"
        local y="20${BASH_REMATCH[3]}"
        local h="${BASH_REMATCH[4]}"
        local mi="${BASH_REMATCH[5]}"
        echo "${y}:${mo}:${d} ${h}:${mi}:00"
        return
    fi

    # Pattern 3: YYYYMMDD anywhere in filename (e.g. IMG_20141008)
    # Anchored so it does not match inside a longer unbroken digit sequence
    local pat_yyyymmdd='(^|[^0-9])([0-9]{4})([0-9]{2})([0-9]{2})([^0-9]|$)'
    if [[ "$base" =~ $pat_yyyymmdd ]]; then
        local y="${BASH_REMATCH[2]}"
        local mo="${BASH_REMATCH[3]}"
        local d="${BASH_REMATCH[4]}"
        echo "${y}:${mo}:${d} 00:00:00"
        return
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Helper: parse date from directory path
# Expects path to contain /YYYY/MM/ somewhere
# Returns exiftool-format date string or empty
# ---------------------------------------------------------------------------
parse_date_from_dir() {
    local filepath="$1"
    local dir
    dir=$(dirname "$filepath")

    # Match /YYYY/MM at end of path or anywhere
    if [[ "$dir" =~ /([0-9]{4})/([0-9]{2})(/|$) ]]; then
        local y="${BASH_REMATCH[1]}"
        local mo="${BASH_REMATCH[2]}"
        echo "${y}:${mo}:01 00:00:00"
        return
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Helper: attempt to parse a standalone 4-digit year from filename
# Lowest-confidence date source — only tried after filename and directory
# parsing both fail. Matches a bounded year token (e.g. "Andrew 1989.jpg",
# "1999-notes.jpg") but not one embedded in a longer digit run
# (e.g. "DSC02021" has no 4-digit window with non-digit neighbors on both
# sides). Rejects years in the future. Defaults month/day to 01/01 since
# only the year is known.
# Returns exiftool-format date string or empty
# ---------------------------------------------------------------------------
parse_year_only_from_filename() {
    local filename="$1"
    local base
    base=$(basename "$filename")
    base="${base%.*}"  # strip extension

    local pat_year_only='(^|[^0-9])((19|20)[0-9]{2})([^0-9]|$)'
    if [[ "$base" =~ $pat_year_only ]]; then
        local y="${BASH_REMATCH[2]}"
        local current_year
        current_year=$(date +%Y)
        if [[ "$y" -le "$current_year" ]]; then
            echo "${y}:01:01 00:00:00"
            return
        fi
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Helper: check that YYYY/MM components are plausible
# ---------------------------------------------------------------------------
is_valid_year_month() {
    local y="$1"
    local mo="$2"
    [[ "$y" -ge 1800 && "$y" -le 2100 && "$mo" -ge 1 && "$mo" -le 12 ]]
}

# ---------------------------------------------------------------------------
# Helper: determine if a name (filename base or directory name) is descriptive
# Returns 0 (true) if descriptive, 1 if camera-generated
# Uses same logic as exif-classify.sh
# ---------------------------------------------------------------------------
is_descriptive() {
    local name="${1,,}"  # lowercase for prefix checks
    local name_orig="$1"
    local name_upper="${1^^}"

    # Date-like patterns — not descriptive
    local pat_datetime='^[0-9]{4}-[0-9]{2}-[0-9]{2}[_ ][0-9]{2}\.[0-9]{2}\.[0-9]{2}'
    [[ "$name_orig" =~ $pat_datetime ]] && return 1
    local pat_yyyymmdd_hhmmss='[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])_([01][0-9]|2[0-3])[0-5][0-9][0-5][0-9]'
    [[ "$name_orig" =~ $pat_yyyymmdd_hhmmss ]] && return 1
    local pat_yyyymmdd='(1[89][0-9]{2}|20[0-9]{2}|21[0]{2})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])'
    [[ "$name_orig" =~ $pat_yyyymmdd ]] && return 1
    local pat_mmddyyhhmm='^(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([0-9]{2})([01][0-9]|2[0-3])([0-5][0-9])[A-Za-z]*$'
    [[ "$name_orig" =~ $pat_mmddyyhhmm ]] && return 1

    # Camera prefixes — not descriptive
    [[ "$name_upper" =~ ^DSC[A-Z]?[0-9]+[A-Z]?$ ]] && return 1
    [[ "$name_upper" =~ ^SAM_[0-9]+ ]] && return 1
    [[ "$name" =~ ^downsized ]] && return 1
    [[ "$name" =~ ^attach[0-9]+ ]] && return 1
    for prefix in "IMG_" "IMAG" "DSCN" "MVI_" "VID_" "MOV_" "P[0-9]"; do
        [[ "$name_upper" =~ ^$prefix ]] && return 1
    done

    # Camera serial patterns — not descriptive
    [[ "$name_orig" =~ ^[0-9]{3}_[0-9]{4}(_[A-Za-z])?$ ]] && return 1
    [[ "$name_orig" =~ ^[0-9]+_[0-9]+[A-Za-z]?$ ]] && return 1
    [[ "$name" =~ ^[0-9]?img[0-9]+$ ]] && return 1
    [[ "$name_orig" =~ ^[0-9]{4}[A-Za-z][A-Za-z0-9]*$ ]] && return 1
    [[ "$name_orig" =~ ^[0-9]{3,}$ ]] && return 1

    # Anything remaining is descriptive
    return 0
}

# ---------------------------------------------------------------------------
# Helper: derive description string from file path
# Combines descriptive subdirectory (beneath YYYY/MM) and/or descriptive filename
# Returns empty string if neither component is descriptive
# ---------------------------------------------------------------------------
derive_description() {
    local filepath="$1"
    local base_dir="$2"

    local rel_path="${filepath#$base_dir/}"
    # rel_path is now: [YYYY/MM/]subdir[/subdir...]/filename.ext

    # Strip YYYY/MM prefix only if actually present — otherwise the first
    # path component itself is the descriptive label (e.g. a topic-named
    # folder with no date structure at all).
    local after_ym="$rel_path"
    if [[ "$rel_path" =~ ^[0-9]{4}/[0-9]{2}/ ]]; then
        after_ym="${rel_path#*/*/}"
    fi
    # after_ym is now: [subdir[/subdir...]/]filename.ext

    # Separate the filename from any subdirectory path
    local subdir_path=""
    local filename
    filename=$(basename "$after_ym")
    local filename_base="${filename%.*}"

    if [[ "$after_ym" == */* ]]; then
        subdir_path="${after_ym%/*}"  # everything before the last /
    fi

    # Use only the immediate first subdirectory level as the descriptive label
    # e.g. "Teachers 50-miler Day1/Camp at Marion Lake" -> label is "Teachers 50-miler Day1"
    local subdir_label=""
    if [[ -n "$subdir_path" ]]; then
        subdir_label="${subdir_path%%/*}"  # first path component only
    fi

    local desc_subdir=""
    local desc_filename=""

    if [[ -n "$subdir_label" ]] && is_descriptive "$subdir_label"; then
        desc_subdir="$subdir_label"
    fi

    if is_descriptive "$filename_base"; then
        desc_filename="$filename_base"
    fi

    # Combine
    if [[ -n "$desc_subdir" && -n "$desc_filename" ]]; then
        echo "${desc_subdir} - ${desc_filename}"
    elif [[ -n "$desc_subdir" ]]; then
        echo "$desc_subdir"
    elif [[ -n "$desc_filename" ]]; then
        echo "$desc_filename"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Main loop: walk only YYYY/MM subdirectories of BASE_DIR
# ---------------------------------------------------------------------------
while IFS= read -r -d '' file; do

    ext="${file##*.}"
    ext_lower="${ext,,}"
    rel_path="${file#$BASE_DIR/}"

    # Recognized video types are valid Immich assets but have no EXIF fields
    # for this script to audit/write — tally separately, not as a skip.
    if is_video "$ext_lower"; then
        log "NON-PHOTO [video:$ext_lower] $file"
        (( count_video++ )) || true
        continue
    fi

    # Check file type
    if ! is_photo "$ext_lower"; then
        log "SKIP [type:$ext_lower] $file"
        (( skipped_type_counts[$ext_lower]++ )) || true
        (( count_skipped_type++ )) || true
        continue
    fi

    (( count_processed++ )) || true

    # -----------------------------------------------------------------------
    # DateTimeOriginal
    # -----------------------------------------------------------------------
    existing_date=$(get_exif_date "$file")
    needs_date=false
    new_date=""
    date_source=""

    if [[ -z "$existing_date" ]]; then
        (( count_missing++ )) || true
        needs_date=true

        # Try filename first, fall back to directory (in both modes, so
        # report previews exactly what update would do)
        new_date=$(parse_date_from_filename "$file")
        if [[ -n "$new_date" ]]; then
            date_source="filename"
        else
            new_date=$(parse_date_from_dir "$file")
            if [[ -n "$new_date" ]]; then
                date_source="directory"
            else
                new_date=$(parse_year_only_from_filename "$file")
                if [[ -n "$new_date" ]]; then
                    date_source="filename-year-only"
                fi
            fi
        fi

        if [[ -z "$new_date" ]]; then
            log "NEEDS REVIEW [no date source] $file"
            (( count_needs_review++ )) || true
            continue
        fi

        if [[ "$MODE" == "report" ]]; then
            log "MISSING [date:$date_source] $new_date  $file"
        fi
    fi

    # -----------------------------------------------------------------------
    # Description
    # -----------------------------------------------------------------------
    existing_desc=$(get_exif_desc "$file")
    needs_desc=false
    new_desc=""

    if [[ -z "$existing_desc" ]]; then
        new_desc=$(derive_description "$file" "$BASE_DIR")
        if [[ -n "$new_desc" ]]; then
            needs_desc=true
            (( count_needs_desc++ )) || true
            if [[ "$MODE" == "report" ]]; then
                log "MISSING [desc] $file  =>  $new_desc"
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # Nothing to do for this file
    # -----------------------------------------------------------------------
    if ! $needs_date && ! $needs_desc; then
        (( count_has_date++ )) || true
        continue
    fi

    [[ "$MODE" == "report" ]] && continue

    # -----------------------------------------------------------------------
    # Update mode: write whatever is needed in a single exiftool call
    # -----------------------------------------------------------------------
    mtime=$(stat -c '%y' "$file")

    exiftool_args=( -overwrite_original )

    if $needs_date; then
        exiftool_args+=(
            -DateTimeOriginal="$new_date"
            -CreateDate="$new_date"
        )
    fi

    if $needs_desc; then
        exiftool_args+=(
            -ImageDescription="$new_desc"
            -XMP-dc:Description="$new_desc"
        )
    fi

    if exiftool "${exiftool_args[@]}" "$file" &>/dev/null; then
        touch -d "$mtime" "$file"

        if $needs_date; then
            log "UPDATED [date:$date_source] $new_date  $file"
            if [[ "$date_source" == "filename" ]]; then
                (( count_updated_filename++ )) || true
            else
                (( count_updated_dir++ )) || true
            fi
        fi
        if $needs_desc; then
            log "UPDATED [desc] \"$new_desc\"  $file"
            (( count_desc_written++ )) || true
        fi
    else
        log "ERROR [exiftool write failed] $file"
        (( count_errors++ )) || true
    fi

done < <(find "$BASE_DIR" -type f -print0 | sort -z)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "========================================"
log "Summary"
log "========================================"
log "Files processed (photo types)             : $count_processed"
log "Already complete (date + desc present)   : $count_has_date"
log "Missing DateTimeOriginal                 : $count_missing"
log "  Needs review (no date source found)    : $count_needs_review"
log "Needs description added                  : $count_needs_desc"
if [[ "$MODE" == "update" ]]; then
log "  Updated from filename                  : $count_updated_filename"
log "  Updated from directory                 : $count_updated_dir"
log "Description written                      : $count_desc_written"
log "Errors                                   : $count_errors"
fi
log "Non-photo (video, not processed)         : $count_video"
log "Skipped (unsupported file type)          : $count_skipped_type"
if (( count_skipped_type > 0 )); then
    for ext in $(printf '%s\n' "${!skipped_type_counts[@]}" | sort); do
        log "  .$ext : ${skipped_type_counts[$ext]}"
    done
fi
log "Completed : $(date)"
log "========================================"
