#!/bin/bash
# Auto-Rip Script for Video Discs (DVD/Blu-ray) and Audio CDs
# Triggered by udev when a disc is inserted
# Rips all titles/tracks, looks up metadata, writes success/error files
#
# Usage: autorip.sh <device>
#   device: sr0, sr1, etc. (passed by udev %k)
#
# Install: sudo cp autorip.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/autorip.sh
#
# Dependencies:
#   Video: makemkvcon
#   Audio: abcde, cdparanoia, cd-discid, flac (optional: lame for mp3)

# Ensure PATH includes common binary locations (udev has minimal PATH)
export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH"

# Don't exit on errors - handle them explicitly
# set -euo pipefail  # Disabled - causes silent failures in udev context

# Configuration
OUTPUT_DIR="${AUTORIP_OUTPUT:-/ripped_discs}"
AUDIO_OUTPUT_DIR="${AUTORIP_AUDIO_OUTPUT:-$OUTPUT_DIR/audio}"
VIDEO_OUTPUT_DIR="${AUTORIP_VIDEO_OUTPUT:-$OUTPUT_DIR/video}"
RIPPED_FILE="$OUTPUT_DIR/.ripped_discs"
LOG_TAG="autorip"
AUDIO_FORMAT="${AUTORIP_AUDIO_FORMAT:-flac}"  # flac, mp3, ogg, etc.

# User to run as (leave empty to run as root)
# Set these to run the rip process as a specific user (useful for NFS mounts with root_squash)
AUTORIP_USER="${AUTORIP_USER:-}"
AUTORIP_GROUP="${AUTORIP_GROUP:-}"

# Get device from argument
DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
    logger -t "$LOG_TAG" "ERROR: No device specified"
    exit 1
fi

DEVICE_PATH="/dev/$DEVICE"
LOCK_FILE="/tmp/autorip-${DEVICE}.lock"

# Logging function
log() {
    logger -t "$LOG_TAG" "[$DEVICE] $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$DEVICE] $*"
}

# Detach from udev and run in background
# udev expects RUN commands to complete quickly
# Use systemd-run to create independent transient service
if [[ "${AUTORIP_DETACHED:-}" != "1" ]]; then
    # Build user/group arguments if specified (for NFS root_squash compatibility)
    USER_ARGS=()
    if [[ -n "$AUTORIP_USER" ]]; then
        USER_ARGS+=(--uid="$AUTORIP_USER")
        # Set HOME for the target user (needed for MakeMKV license, abcde config, etc.)
        USER_HOME=$(getent passwd "$AUTORIP_USER" | cut -d: -f6)
        [[ -n "$USER_HOME" ]] && USER_ARGS+=(--setenv=HOME="$USER_HOME")
    fi
    if [[ -n "$AUTORIP_GROUP" ]]; then
        USER_ARGS+=(--gid="$AUTORIP_GROUP")
    fi

    systemd-run --quiet --no-block \
        "${USER_ARGS[@]}" \
        --unit="autorip-${DEVICE}-$(date +%s)" \
        --setenv=AUTORIP_DETACHED=1 \
        --setenv=AUTORIP_OUTPUT="$OUTPUT_DIR" \
        --setenv=AUTORIP_AUDIO_OUTPUT="$AUDIO_OUTPUT_DIR" \
        --setenv=AUTORIP_VIDEO_OUTPUT="$VIDEO_OUTPUT_DIR" \
        --setenv=AUTORIP_AUDIO_FORMAT="$AUDIO_FORMAT" \
        --setenv=AUTORIP_USER="$AUTORIP_USER" \
        --setenv=AUTORIP_GROUP="$AUTORIP_GROUP" \
        --setenv=PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin" \
        "$0" "$@"
    exit 0
fi

# Redirect output to log file when running detached
exec >> "/tmp/autorip-${DEVICE}.log" 2>&1

# Set permissive umask so all created files are world read-write
umask 000

# Acquire lock (per-device, allows parallel rips on different drives)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Already processing disc on $DEVICE, exiting"
    exit 0
fi

# Cleanup on exit
cleanup() {
    flock -u 200 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

log "========================================"
log "Disc detected on $DEVICE_PATH"
log "========================================"

# Wait for disc to be fully ready
sleep 3

# Sanitize name for directory/filename
sanitize_name() {
    local name="$1"
    # Remove control characters
    name=$(echo "$name" | tr -d '[:cntrl:]')
    # Replace unsafe characters with underscore
    name=$(echo "$name" | sed 's/[^a-zA-Z0-9._-]/_/g')
    # Collapse multiple underscores
    name=$(echo "$name" | sed 's/__*/_/g')
    # Remove leading/trailing underscores
    name=$(echo "$name" | sed 's/^_//; s/_$//')
    # Limit length
    name=$(echo "$name" | cut -c1-64)
    # Default if empty
    [[ -z "$name" ]] && name="Unknown"
    echo "$name"
}

# Detect disc type
detect_disc_type() {
    local device="$1"
    local blkid_output

    # First check for data disc using blkid (UDF = Blu-ray/DVD, ISO9660 = DVD/data)
    # This must come FIRST because cd-discid can also read some video discs
    blkid_output=$(blkid "$device" 2>&1)
    echo "[DEBUG] blkid output: $blkid_output" >&2

    if echo "$blkid_output" | grep -qE "TYPE=\"(udf|iso9660)\""; then
        echo "[DEBUG] Detected as video (blkid found filesystem)" >&2
        echo "video"
        return
    fi

    # Check if cd-discid can read it (audio CD has no filesystem)
    if command -v cd-discid &>/dev/null; then
        local discid_output=$(cd-discid "$device" 2>&1)
        echo "[DEBUG] cd-discid output: $discid_output" >&2
        if cd-discid "$device" &>/dev/null; then
            echo "[DEBUG] Detected as audio (cd-discid succeeded)" >&2
            echo "audio"
            return
        fi
    fi

    # Try MakeMKV as fallback for video detection
    if command -v makemkvcon &>/dev/null; then
        echo "[DEBUG] Trying MakeMKV fallback detection" >&2
        local info=$(makemkvcon -r info disc:9999 2>&1)
        if echo "$info" | grep -q "\"$device\""; then
            echo "[DEBUG] Detected as video (MakeMKV found disc)" >&2
            echo "video"
            return
        fi
    fi

    echo "[DEBUG] Could not detect disc type" >&2
    echo "unknown"
}

# ============================================================
# AUDIO CD RIPPING
# ============================================================
rip_audio_cd() {
    log "Detected: Audio CD"

    # Check for required tools
    if ! command -v abcde &>/dev/null; then
        log "ERROR: abcde not installed. Install with: sudo apt install abcde cdparanoia cd-discid flac"
        return 1
    fi

    # Get disc ID for duplicate checking
    local disc_id=""
    if command -v cd-discid &>/dev/null; then
        disc_id=$(cd-discid "$DEVICE_PATH" 2>/dev/null | awk '{print $1}')
    fi

    if [[ -z "$disc_id" ]]; then
        disc_id="audio-$(date +%s)"
    fi

    log "Audio disc ID: $disc_id"

    # Check if already ripped
    if [[ -f "$RIPPED_FILE" ]] && grep -qF "audio:$disc_id" "$RIPPED_FILE"; then
        log "Audio CD already ripped: $disc_id"
        log "Ejecting duplicate disc..."
        eject "$DEVICE_PATH" 2>/dev/null || log "WARNING: Could not eject disc"
        return 0
    fi

    # Create output directory
    mkdir -p "$AUDIO_OUTPUT_DIR"

    # Create abcde config for this rip
    # Include disc_id in path to prevent overwrites when metadata lookup fails
    local abcde_conf=$(mktemp)
    cat > "$abcde_conf" << EOF
# abcde config for autorip
CDROM="$DEVICE_PATH"
OUTPUTDIR="$AUDIO_OUTPUT_DIR"
OUTPUTTYPE="$AUDIO_FORMAT"
ACTIONS=cddb,read,encode,tag,move,clean
CDDBMETHOD=musicbrainz
PADTRACKS=y
NOGAP=y
EJECTCD=n
INTERACTIVE=n
# Naming: Artist/Album_discid/Track - Title
# Include disc ID to prevent overwrites when multiple unknown CDs are ripped
OUTPUTFORMAT='\${ARTISTFILE}/\${ALBUMFILE}_${disc_id}/\${TRACKNUM} - \${TRACKFILE}'
VAOUTPUTFORMAT='Various_Artists/\${ALBUMFILE}_${disc_id}/\${TRACKNUM} - \${ARTISTFILE} - \${TRACKFILE}'
ONETRACKOUTPUTFORMAT='\${ARTISTFILE}/\${ALBUMFILE}_${disc_id}/\${ALBUMFILE}'
VAONETRACKOUTPUTFORMAT='Various_Artists/\${ALBUMFILE}_${disc_id}/\${ALBUMFILE}'
EOF

    log "Starting audio rip with abcde..."
    log "Output format: $AUDIO_FORMAT"
    log "Output directory: $AUDIO_OUTPUT_DIR"

    # Run abcde
    local rip_output=$(mktemp)
    local rip_exit=0
    abcde -c "$abcde_conf" -N -x 2>&1 | tee "$rip_output" || rip_exit=$?

    # Clean up config
    rm -f "$abcde_conf"

    # Check for success
    if [[ $rip_exit -eq 0 ]]; then
        # Try to find what was ripped (abcde creates Artist/Album structure)
        local artist=$(grep -oP "Artist: \K.*" "$rip_output" | head -1 || echo "Unknown")
        local album=$(grep -oP "Album: \K.*" "$rip_output" | head -1 || echo "Unknown")

        log "Audio rip completed successfully!"
        log "Artist: $artist"
        log "Album: $album"

        # Mark as ripped
        echo "audio:$disc_id|$artist - $album|$(date -Iseconds)" >> "$RIPPED_FILE"

        # Create success marker in output dir if we can find it
        local safe_artist=$(sanitize_name "$artist")
        local album_dir="$AUDIO_OUTPUT_DIR/$safe_artist"
        if [[ -d "$album_dir" ]]; then
            echo "Audio CD ripped successfully at $(date -Iseconds)" > "$album_dir/success.txt"
        fi

        # Eject disc
        log "Ejecting disc..."
        for attempt in 1 2 3 4 5; do
            sleep 2
            if eject "$DEVICE_PATH" 2>/dev/null; then
                log "Disc ejected successfully"
                break
            fi
            log "Eject attempt $attempt failed, retrying..."
        done
    else
        log "Audio rip FAILED!"
        log "Exit code: $rip_exit"

        # Create error directory
        local error_dir="$AUDIO_OUTPUT_DIR/_errors/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$error_dir"
        cp "$rip_output" "$error_dir/rip_output.txt"

        {
            echo "AUDIO CD RIP FAILED"
            echo "==================="
            echo "Device: $DEVICE_PATH"
            echo "Disc ID: $disc_id"
            echo "Date: $(date -Iseconds)"
            echo "Exit Code: $rip_exit"
            echo ""
            echo "TO RETRY MANUALLY:"
            echo "abcde -d $DEVICE_PATH -o $AUDIO_FORMAT -N"
        } > "$error_dir/error.txt"

        log "Error details saved to: $error_dir"
        # Do NOT eject on failure - allow manual retry
    fi

    rm -f "$rip_output"
}

# ============================================================
# VIDEO DISC RIPPING (DVD/Blu-ray)
# ============================================================
rip_video_disc() {
    log "Detected: Video disc (DVD/Blu-ray)"

    # Find MakeMKV drive index for this device
    get_drive_index() {
        local device_path="$1"
        local info
        local line
        local idx

        echo "[DEBUG] Getting drive index for $device_path..." >&2

        if ! info=$(makemkvcon -r info disc:9999 2>&1); then
            echo "[DEBUG] WARNING: makemkvcon returned non-zero exit code" >&2
        fi

        echo "[DEBUG] makemkvcon returned ${#info} bytes" >&2

        line=$(echo "$info" | grep -E "^DRV:[0-9]+.*\"$device_path\"" | head -1) || true
        echo "[DEBUG] Matched line: $line" >&2

        if [[ -n "$line" ]]; then
            idx="${line#DRV:}"
            idx="${idx%%,*}"
            echo "[DEBUG] Extracted drive index: $idx" >&2
            echo "$idx"
        else
            echo "[DEBUG] ERROR: No DRV line matched $device_path" >&2
        fi
    }

    DRIVE_INDEX=$(get_drive_index "$DEVICE_PATH")
    if [[ -z "$DRIVE_INDEX" ]]; then
        log "ERROR: Could not find MakeMKV drive index for $DEVICE_PATH"
        return 1
    fi

    log "Drive index: $DRIVE_INDEX"

    # Get disc info
    log "Getting disc info..."
    log "Running: makemkvcon -r info disc:$DRIVE_INDEX"
    DISC_INFO=$(makemkvcon -r info "disc:$DRIVE_INDEX" 2>&1) || true

    # Debug: show what we got
    log "DISC_INFO length: ${#DISC_INFO} bytes"
    TCOUNT_LINE=$(echo "$DISC_INFO" | grep "TCOUNT" || echo "NO TCOUNT FOUND")
    log "TCOUNT line: $TCOUNT_LINE"

    # Check if disc has titles
    if ! echo "$DISC_INFO" | grep -qE "TCOUNT:[1-9]"; then
        log "No rippable titles found on disc"
        return 0
    fi

    # Extract disc name (CINFO:2,0,"name")
    DISC_NAME=$(echo "$DISC_INFO" | grep -oP 'CINFO:2,0,"\K[^"]+' || echo "Unknown")
    log "Disc name: $DISC_NAME"

    # Generate disc ID hash for duplicate detection
    DISC_ID_HASH=$(echo "$DISC_INFO" | grep -E "^(CINFO|TCOUNT)" | md5sum | cut -c1-16)
    DISC_ID="video:${DISC_NAME}:${DISC_ID_HASH}"
    log "Disc ID: $DISC_ID"

    # Check if already ripped
    if [[ -f "$RIPPED_FILE" ]] && grep -qF "$DISC_ID" "$RIPPED_FILE"; then
        log "Disc already ripped: $DISC_ID"
        log "Ejecting duplicate disc..."
        eject "$DEVICE_PATH" 2>/dev/null || log "WARNING: Could not eject disc"
        return 0
    fi

    # Generate GUID and create output directory
    GUID=$(cat /proc/sys/kernel/random/uuid | cut -c1-8)
    SAFE_NAME=$(sanitize_name "$DISC_NAME")
    RIP_DIR="$VIDEO_OUTPUT_DIR/${GUID}-${SAFE_NAME}"

    mkdir -p "$RIP_DIR"
    log "Output directory: $RIP_DIR"

    # Save raw disc info
    echo "$DISC_INFO" > "$RIP_DIR/disc_info_raw.txt"

    # Parse and save disc info as JSON
    {
        echo "{"
        echo "  \"name\": \"$DISC_NAME\","
        echo "  \"hash\": \"$DISC_ID_HASH\","
        echo "  \"device\": \"$DEVICE_PATH\","
        echo "  \"driveIndex\": $DRIVE_INDEX,"
        echo "  \"ripDate\": \"$(date -Iseconds)\","

        TITLE_COUNT=$(echo "$DISC_INFO" | grep -oP 'TCOUNT:\K\d+' || echo "0")
        echo "  \"titleCount\": $TITLE_COUNT,"

        echo "  \"titles\": ["
        first=true
        for i in $(seq 0 $((TITLE_COUNT - 1))); do
            [[ "$first" == "true" ]] || echo ","
            first=false

            title_name=$(echo "$DISC_INFO" | grep -oP "TINFO:$i,2,0,\"\K[^\"]+" || echo "")
            duration=$(echo "$DISC_INFO" | grep -oP "TINFO:$i,9,0,\"\K[^\"]+" || echo "")
            size=$(echo "$DISC_INFO" | grep -oP "TINFO:$i,10,0,\"\K[^\"]+" || echo "")

            printf '    {"index": %d, "name": "%s", "duration": "%s", "size": "%s"}' \
                "$i" "$title_name" "$duration" "$size"
        done
        echo ""
        echo "  ]"
        echo "}"
    } > "$RIP_DIR/disc_info.json"

    # Run MakeMKV rip
    log "Starting rip..."
    log "Command: makemkvcon -r mkv disc:$DRIVE_INDEX all \"$RIP_DIR\""

    RIP_OUTPUT=$(mktemp)
    RIP_EXIT_CODE=0
    makemkvcon -r mkv "disc:$DRIVE_INDEX" all "$RIP_DIR" 2>&1 | tee "$RIP_OUTPUT" || RIP_EXIT_CODE=$?

    # Parse results
    TITLES_SAVED=$(grep -oP 'MSG:5005,\d+,\d+,"\K\d+(?= titles? saved)' "$RIP_OUTPUT" || echo "0")
    COPY_COMPLETE=$(grep -oP 'MSG:5036,\d+,\d+,"Copy complete\. \K\d+' "$RIP_OUTPUT" || echo "")

    # Check for actual output files
    MKV_FILES=$(find "$RIP_DIR" -name "*.mkv" -type f 2>/dev/null | wc -l)

    # Determine success
    SUCCESS=false
    if [[ "$RIP_EXIT_CODE" -eq 0 ]] && [[ "$MKV_FILES" -gt 0 ]]; then
        if [[ -n "$COPY_COMPLETE" ]] || [[ "$TITLES_SAVED" -gt 0 ]]; then
            SUCCESS=true
        fi
    fi

    if [[ "$SUCCESS" == "true" ]]; then
        log "Rip completed successfully!"
        log "Titles saved: ${TITLES_SAVED:-$COPY_COMPLETE}"
        log "MKV files: $MKV_FILES"

        {
            echo "DISC RIP SUCCESSFUL"
            echo "==================="
            echo "Disc Name: $DISC_NAME"
            echo "Device: $DEVICE_PATH"
            echo "Date: $(date -Iseconds)"
            echo ""
            echo "RESULTS:"
            echo "Titles Saved: ${TITLES_SAVED:-$COPY_COMPLETE}"
            echo "Output Directory: $RIP_DIR"
            echo ""
            echo "FILES:"
            find "$RIP_DIR" -name "*.mkv" -type f -printf "  - %f\n" 2>/dev/null || true
        } > "$RIP_DIR/success.txt"

        echo "$DISC_ID|$RIP_DIR|$(date -Iseconds)" >> "$RIPPED_FILE"

        log "Ejecting disc..."
        for attempt in 1 2 3 4 5; do
            sleep 2
            if eject "$DEVICE_PATH" 2>/dev/null; then
                log "Disc ejected successfully"
                break
            fi
            log "Eject attempt $attempt failed, retrying..."
        done
    else
        log "Rip FAILED!"
        log "Exit code: $RIP_EXIT_CODE"
        log "MKV files: $MKV_FILES"

        LAST_ERROR=$(grep -E "MSG:2003|MSG:5010|MSG:2010" "$RIP_OUTPUT" | tail -1 || echo "Unknown error")

        {
            echo "DISC RIP FAILED"
            echo "==============="
            echo "Disc Name: $DISC_NAME"
            echo "Device: $DEVICE_PATH"
            echo "Date: $(date -Iseconds)"
            echo "Exit Code: $RIP_EXIT_CODE"
            echo ""
            echo "LAST ERROR:"
            echo "$LAST_ERROR"
            echo ""
            echo "TO RETRY MANUALLY:"
            echo "1. Insert disc in drive"
            echo "2. Run: makemkvcon mkv disc:$DRIVE_INDEX all \"$RIP_DIR\""
        } > "$RIP_DIR/error.txt"

        log "Error file written: $RIP_DIR/error.txt"
    fi

    rm -f "$RIP_OUTPUT"
}

# ============================================================
# MAIN
# ============================================================

# Detect disc type and route to appropriate ripper
DISC_TYPE=$(detect_disc_type "$DEVICE_PATH")
log "Disc type detected: $DISC_TYPE"

case "$DISC_TYPE" in
    audio)
        rip_audio_cd
        ;;
    video)
        rip_video_disc
        ;;
    *)
        log "Unknown disc type - trying video first, then audio"
        # Try video first (most common)
        if command -v makemkvcon &>/dev/null; then
            rip_video_disc
        elif command -v abcde &>/dev/null; then
            rip_audio_cd
        else
            log "ERROR: No ripping tools available (need makemkvcon or abcde)"
            exit 1
        fi
        ;;
esac

log "========================================"
log "Done processing $DEVICE"
log "========================================"
