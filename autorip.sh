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

# Web interface status directories
STATUS_DIR="${AUTORIP_STATUS_DIR:-/var/lib/autorip/status}"
HISTORY_FILE="${AUTORIP_HISTORY_FILE:-/var/lib/autorip/history.json}"
HEARTBEAT_INTERVAL=30  # seconds between heartbeat updates

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

# ============================================================
# STATUS REPORTING FOR WEB INTERFACE
# ============================================================

# Global status variables
STATUS_FILE=""
HEARTBEAT_PID=""
RIP_START_TIME=""

# Initialize status directory and file
init_status() {
    mkdir -p "$STATUS_DIR"
    STATUS_FILE="$STATUS_DIR/${DEVICE}.json"
    RIP_START_TIME=$(date +%s)
}

# Write status to JSON file (atomic write via temp file)
write_status() {
    local state="$1"
    local disc_name="${2:-}"
    local disc_type="${3:-}"
    local progress="${4:-0}"
    local eta="${5:-}"
    local operation="${6:-}"
    local error_msg="${7:-}"
    local title_current="${8:-0}"
    local title_total="${9:-0}"

    local now=$(date +%s)
    local now_iso=$(date -Iseconds)
    local elapsed=$((now - RIP_START_TIME))

    # Create temp file and write atomically
    local temp_file=$(mktemp)
    cat > "$temp_file" << EOF
{
  "device": "$DEVICE",
  "devicePath": "$DEVICE_PATH",
  "state": "$state",
  "discName": "$disc_name",
  "discType": "$disc_type",
  "progress": $progress,
  "eta": "$eta",
  "operation": "$operation",
  "titleCurrent": $title_current,
  "titleTotal": $title_total,
  "errorMessage": "$error_msg",
  "startTime": "$RIP_START_TIME",
  "elapsed": $elapsed,
  "heartbeat": $now,
  "heartbeatIso": "$now_iso",
  "logFile": "/tmp/autorip-${DEVICE}.log"
}
EOF
    mv "$temp_file" "$STATUS_FILE"
    chmod 644 "$STATUS_FILE" 2>/dev/null || true
}

# Update heartbeat only (keeps existing status but updates timestamp)
update_heartbeat() {
    if [[ -f "$STATUS_FILE" ]]; then
        local now=$(date +%s)
        local now_iso=$(date -Iseconds)
        local elapsed=$((now - RIP_START_TIME))
        # Use sed to update heartbeat fields in-place
        local temp_file=$(mktemp)
        sed -e "s/\"heartbeat\": [0-9]*/\"heartbeat\": $now/" \
            -e "s/\"heartbeatIso\": \"[^\"]*\"/\"heartbeatIso\": \"$now_iso\"/" \
            -e "s/\"elapsed\": [0-9]*/\"elapsed\": $elapsed/" \
            "$STATUS_FILE" > "$temp_file"
        mv "$temp_file" "$STATUS_FILE"
    fi
}

# Start background heartbeat updater
start_heartbeat() {
    (
        while true; do
            sleep "$HEARTBEAT_INTERVAL"
            update_heartbeat
        done
    ) &
    HEARTBEAT_PID=$!
}

# Stop background heartbeat updater
stop_heartbeat() {
    if [[ -n "$HEARTBEAT_PID" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# Clear status file (drive is idle)
clear_status() {
    if [[ -f "$STATUS_FILE" ]]; then
        write_status "idle" "" "" 0 "" "" "" 0 0
    fi
}

# Add entry to history file
add_history_entry() {
    local disc_name="$1"
    local disc_type="$2"
    local status="$3"
    local output_dir="$4"
    local error_msg="${5:-}"
    local titles_total="${6:-0}"
    local titles_succeeded="${7:-0}"
    local titles_failed="${8:-0}"
    local failed_titles_json="${9:-[]}"

    local end_time=$(date +%s)
    local duration=$((end_time - RIP_START_TIME))
    local history_dir=$(dirname "$HISTORY_FILE")
    mkdir -p "$history_dir"

    # Create entry JSON
    local entry=$(cat << EOF
{
    "id": "$(cat /proc/sys/kernel/random/uuid)",
    "device": "$DEVICE",
    "discName": "$disc_name",
    "discType": "$disc_type",
    "status": "$status",
    "startTime": $RIP_START_TIME,
    "endTime": $end_time,
    "duration": $duration,
    "outputDir": "$output_dir",
    "errorMessage": "$error_msg",
    "titlesTotal": $titles_total,
    "titlesSucceeded": $titles_succeeded,
    "titlesFailed": $titles_failed,
    "failedTitles": $failed_titles_json
}
EOF
)

    # Append to history with file locking
    (
        flock -x 202
        # Read existing history or create empty array
        local history="[]"
        if [[ -f "$HISTORY_FILE" ]]; then
            history=$(cat "$HISTORY_FILE" 2>/dev/null || echo "[]")
        fi

        # Prepend new entry and limit to 1000 entries
        # Using a simple approach: write entry, then existing entries
        local temp_file=$(mktemp)
        echo "[" > "$temp_file"
        echo "$entry" >> "$temp_file"

        # Add existing entries (up to 999 more)
        if [[ "$history" != "[]" ]]; then
            # Extract entries from existing array, skip first [ and last ]
            local existing=$(echo "$history" | sed '1d;$d')
            if [[ -n "$existing" ]]; then
                echo "," >> "$temp_file"
                echo "$existing" >> "$temp_file"
            fi
        fi
        echo "]" >> "$temp_file"

        # Limit to 1000 entries using jq if available, otherwise keep as-is
        if command -v jq &>/dev/null; then
            jq '.[0:1000]' "$temp_file" > "${temp_file}.limited" && mv "${temp_file}.limited" "$temp_file"
        fi

        mv "$temp_file" "$HISTORY_FILE"
        chmod 644 "$HISTORY_FILE" 2>/dev/null || true
    ) 202>/tmp/autorip-history.lock
}

# File locking for shared RIPPED_FILE access (prevents race conditions with parallel rips)
RIPPED_FILE_LOCK="/tmp/autorip-ripped.lock"

# Check if disc ID exists in ripped file (with locking)
is_already_ripped() {
    local disc_id="$1"
    (
        flock -s 201
        [[ -f "$RIPPED_FILE" ]] && grep -qF "$disc_id" "$RIPPED_FILE"
    ) 201>"$RIPPED_FILE_LOCK"
}

# Add disc ID to ripped file (with locking)
mark_as_ripped() {
    local entry="$1"
    (
        flock -x 201
        echo "$entry" >> "$RIPPED_FILE"
    ) 201>"$RIPPED_FILE_LOCK"
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
    stop_heartbeat
    clear_status
    flock -u 200 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# Initialize status reporting
init_status

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

    # Try MakeMKV as fallback for video detection (use dev: to query only this drive)
    if command -v makemkvcon &>/dev/null; then
        echo "[DEBUG] Trying MakeMKV fallback detection for $device" >&2
        local info=$(makemkvcon -r info "dev:$device" 2>&1)
        if echo "$info" | grep -qE "TCOUNT:[0-9]+"; then
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
    write_status "detecting" "" "audio" 0 "" "Detecting audio CD"

    # Check for required tools
    if ! command -v abcde &>/dev/null; then
        log "ERROR: abcde not installed. Install with: sudo apt install abcde cdparanoia cd-discid flac"
        write_status "error" "" "audio" 0 "" "" "abcde not installed"
        add_history_entry "Unknown" "audio" "error" "" "abcde not installed"
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

    # Check if already ripped (with file locking for parallel safety)
    if is_already_ripped "audio:$disc_id"; then
        log "Audio CD already ripped: $disc_id"
        log "Ejecting duplicate disc..."
        write_status "ejecting" "Duplicate" "audio" 100 "" "Ejecting duplicate disc"
        eject "$DEVICE_PATH" 2>/dev/null || log "WARNING: Could not eject disc"
        clear_status
        return 0
    fi

    # Create output directory
    mkdir -p "$AUDIO_OUTPUT_DIR"

    # Create abcde config for this rip
    # Include disc_id in path to prevent overwrites when metadata lookup fails
    local abcde_conf=$(mktemp)
    local abcde_tempdir="/tmp/abcde-$$-${disc_id}"
    mkdir -p "$abcde_tempdir"
    cat > "$abcde_conf" << EOF
# abcde config for autorip
CDROM="$DEVICE_PATH"
OUTPUTDIR="$AUDIO_OUTPUT_DIR"
WAVOUTPUTDIR="$abcde_tempdir"
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

    # Update status and start heartbeat
    write_status "ripping" "Audio CD" "audio" 0 "" "Starting rip"
    start_heartbeat

    # Run abcde with progress parsing
    local rip_output=$(mktemp)
    local rip_exit=0
    local track_count=0
    local current_track=0

    # Run abcde and parse output for progress
    abcde -c "$abcde_conf" -N -x 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$rip_output"
        echo "$line"
        # Parse track progress from abcde output
        if [[ "$line" =~ "Grabbing track" ]]; then
            current_track=$((current_track + 1))
            if [[ $track_count -gt 0 ]]; then
                local progress=$((current_track * 100 / track_count))
                write_status "ripping" "Audio CD" "audio" "$progress" "" "Ripping track $current_track of $track_count" "" "$current_track" "$track_count"
            fi
        elif [[ "$line" =~ "tracks" ]] && [[ "$line" =~ [0-9]+ ]]; then
            # Try to extract track count
            track_count=$(echo "$line" | grep -oP '\d+(?=\s+tracks?)' | head -1 || echo "0")
        fi
    done
    rip_exit=${PIPESTATUS[0]}

    # Clean up config
    rm -f "$abcde_conf"

    # Stop heartbeat
    stop_heartbeat

    # Check for success
    if [[ $rip_exit -eq 0 ]]; then
        # Try to find what was ripped (abcde creates Artist/Album structure)
        local artist=$(grep -oP "Artist: \K.*" "$rip_output" | head -1 || echo "Unknown")
        local album=$(grep -oP "Album: \K.*" "$rip_output" | head -1 || echo "Unknown")
        local disc_name="$artist - $album"

        log "Audio rip completed successfully!"
        log "Artist: $artist"
        log "Album: $album"

        write_status "ejecting" "$disc_name" "audio" 100 "" "Rip complete, ejecting"

        # Mark as ripped (with file locking for parallel safety)
        mark_as_ripped "audio:$disc_id|$disc_name|$(date -Iseconds)"

        # Create success marker in output dir if we can find it
        local safe_artist=$(sanitize_name "$artist")
        local album_dir="$AUDIO_OUTPUT_DIR/$safe_artist"
        if [[ -d "$album_dir" ]]; then
            echo "Audio CD ripped successfully at $(date -Iseconds)" > "$album_dir/success.txt"
        fi

        # Add to history
        add_history_entry "$disc_name" "audio" "success" "$album_dir"

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

        clear_status
    else
        log "Audio rip FAILED!"
        log "Exit code: $rip_exit"

        # Create error directory
        local error_dir="$AUDIO_OUTPUT_DIR/_errors/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$error_dir"
        cp "$rip_output" "$error_dir/rip_output.txt"

        local error_msg="Exit code: $rip_exit"

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

        write_status "error" "Audio CD" "audio" 0 "" "" "$error_msg"
        add_history_entry "Audio CD" "audio" "error" "$error_dir" "$error_msg"

        log "Error details saved to: $error_dir"
        # Do NOT eject on failure - allow manual retry
    fi

    rm -f "$rip_output"
    rm -rf "$abcde_tempdir"
}

# ============================================================
# VIDEO DISC RIPPING (DVD/Blu-ray)
# ============================================================
rip_video_disc() {
    log "Detected: Video disc (DVD/Blu-ray)"
    write_status "detecting" "" "video" 0 "" "Detecting video disc"

    # Use dev: syntax to address drive directly by device path
    # This avoids race conditions when multiple drives are ripping simultaneously
    DRIVE_SPEC="dev:$DEVICE_PATH"
    log "Using drive spec: $DRIVE_SPEC"

    # Get disc info
    log "Getting disc info..."
    log "Running: makemkvcon -r info $DRIVE_SPEC"
    write_status "detecting" "" "video" 0 "" "Reading disc information"
    DISC_INFO=$(makemkvcon -r info "$DRIVE_SPEC" 2>&1) || true

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

    # Check if already ripped (with file locking for parallel safety)
    if is_already_ripped "$DISC_ID"; then
        log "Disc already ripped: $DISC_ID"
        log "Ejecting duplicate disc..."
        write_status "ejecting" "$DISC_NAME" "video" 100 "" "Ejecting duplicate disc"
        eject "$DEVICE_PATH" 2>/dev/null || log "WARNING: Could not eject disc"
        clear_status
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
        echo "  \"driveSpec\": \"$DRIVE_SPEC\","
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

    # Run MakeMKV rip with progress tracking
    log "Starting rip..."
    log "Command: makemkvcon -r mkv $DRIVE_SPEC all \"$RIP_DIR\""

    write_status "ripping" "$DISC_NAME" "video" 0 "" "Starting rip" "" 0 "$TITLE_COUNT"
    start_heartbeat

    RIP_OUTPUT=$(mktemp)
    RIP_EXIT_CODE=0
    local current_title=0
    local progress=0
    local last_progress_update=0

    # Run MakeMKV and parse progress output
    makemkvcon -r mkv "$DRIVE_SPEC" all "$RIP_DIR" 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$RIP_OUTPUT"
        echo "$line"

        # Parse PRGV (progress) messages: PRGV:current,total,max
        if [[ "$line" =~ ^PRGV:([0-9]+),([0-9]+),([0-9]+) ]]; then
            local prgv_current="${BASH_REMATCH[1]}"
            local prgv_total="${BASH_REMATCH[2]}"
            local prgv_max="${BASH_REMATCH[3]}"
            if [[ "$prgv_max" -gt 0 ]]; then
                progress=$((prgv_current * 100 / prgv_max))
                # Only update status every 2% to reduce file I/O
                if [[ $((progress - last_progress_update)) -ge 2 ]] || [[ "$progress" -eq 100 ]]; then
                    last_progress_update=$progress
                    write_status "ripping" "$DISC_NAME" "video" "$progress" "" "Ripping" "" "$current_title" "$TITLE_COUNT"
                fi
            fi
        # Parse PRGT (progress title) messages for current title info
        elif [[ "$line" =~ ^PRGT:([0-9]+), ]]; then
            current_title="${BASH_REMATCH[1]}"
            write_status "ripping" "$DISC_NAME" "video" "$progress" "" "Ripping title $((current_title + 1)) of $TITLE_COUNT" "" "$((current_title + 1))" "$TITLE_COUNT"
        # Parse PRGC (progress current) for operation details
        elif [[ "$line" =~ ^PRGC:([0-9]+),([0-9]+),\"(.*)\" ]]; then
            local operation="${BASH_REMATCH[3]}"
            if [[ -n "$operation" ]]; then
                write_status "ripping" "$DISC_NAME" "video" "$progress" "" "$operation" "" "$((current_title + 1))" "$TITLE_COUNT"
            fi
        fi
    done
    RIP_EXIT_CODE=${PIPESTATUS[0]}

    # Stop heartbeat
    stop_heartbeat

    # Parse results
    TITLES_SAVED=$(grep -oP 'MSG:5005,\d+,\d+,"\K\d+(?= titles? saved)' "$RIP_OUTPUT" || echo "0")
    COPY_COMPLETE=$(grep -oP 'MSG:5036,\d+,\d+,"Copy complete\. \K\d+' "$RIP_OUTPUT" || echo "")

    # Parse title-level errors for partial failure detection
    local failed_titles_json="[]"
    local titles_failed=0
    local title_errors=$(grep -E "MSG:(5010|2010|2003)" "$RIP_OUTPUT" || true)
    if [[ -n "$title_errors" ]]; then
        # Build JSON array of failed titles
        failed_titles_json="["
        local first=true
        while IFS= read -r err_line; do
            if [[ "$err_line" =~ MSG:[0-9]+,[0-9]+,[0-9]+,\"(.*)\" ]]; then
                local err_msg="${BASH_REMATCH[1]}"
                [[ "$first" == "true" ]] || failed_titles_json+=","
                first=false
                failed_titles_json+="{\"error\":\"$(echo "$err_msg" | sed 's/"/\\"/g')\"}"
                titles_failed=$((titles_failed + 1))
            fi
        done <<< "$title_errors"
        failed_titles_json+="]"
    fi

    # Check for actual output files
    MKV_FILES=$(find "$RIP_DIR" -name "*.mkv" -type f 2>/dev/null | wc -l)

    # Determine success and status
    local rip_status="error"
    local titles_succeeded=$((MKV_FILES))

    if [[ "$RIP_EXIT_CODE" -eq 0 ]] && [[ "$MKV_FILES" -gt 0 ]]; then
        if [[ -n "$COPY_COMPLETE" ]] || [[ "$TITLES_SAVED" -gt 0 ]]; then
            if [[ "$titles_failed" -gt 0 ]]; then
                rip_status="partial"
            else
                rip_status="success"
            fi
        fi
    fi

    if [[ "$rip_status" == "success" ]] || [[ "$rip_status" == "partial" ]]; then
        if [[ "$rip_status" == "partial" ]]; then
            log "Rip completed with partial success!"
            log "Titles saved: $titles_succeeded, Titles failed: $titles_failed"
        else
            log "Rip completed successfully!"
            log "Titles saved: ${TITLES_SAVED:-$COPY_COMPLETE}"
        fi
        log "MKV files: $MKV_FILES"

        write_status "ejecting" "$DISC_NAME" "video" 100 "" "Rip complete, ejecting"

        {
            echo "DISC RIP ${rip_status^^}"
            echo "==================="
            echo "Disc Name: $DISC_NAME"
            echo "Device: $DEVICE_PATH"
            echo "Date: $(date -Iseconds)"
            echo ""
            echo "RESULTS:"
            echo "Titles Saved: ${TITLES_SAVED:-$COPY_COMPLETE}"
            echo "Titles Failed: $titles_failed"
            echo "Output Directory: $RIP_DIR"
            echo ""
            echo "FILES:"
            find "$RIP_DIR" -name "*.mkv" -type f -printf "  - %f\n" 2>/dev/null || true
        } > "$RIP_DIR/success.txt"

        mark_as_ripped "$DISC_ID|$RIP_DIR|$(date -Iseconds)"

        # Add to history
        add_history_entry "$DISC_NAME" "video" "$rip_status" "$RIP_DIR" "" "$TITLE_COUNT" "$titles_succeeded" "$titles_failed" "$failed_titles_json"

        log "Ejecting disc..."
        for attempt in 1 2 3 4 5; do
            sleep 2
            if eject "$DEVICE_PATH" 2>/dev/null; then
                log "Disc ejected successfully"
                break
            fi
            log "Eject attempt $attempt failed, retrying..."
        done

        clear_status
    else
        log "Rip FAILED!"
        log "Exit code: $RIP_EXIT_CODE"
        log "MKV files: $MKV_FILES"

        LAST_ERROR=$(grep -E "MSG:2003|MSG:5010|MSG:2010" "$RIP_OUTPUT" | tail -1 || echo "Unknown error")
        local error_msg="Exit code: $RIP_EXIT_CODE - $LAST_ERROR"

        write_status "error" "$DISC_NAME" "video" 0 "" "" "$error_msg"

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
            echo "2. Run: makemkvcon mkv $DRIVE_SPEC all \"$RIP_DIR\""
        } > "$RIP_DIR/error.txt"

        # Add to history
        add_history_entry "$DISC_NAME" "video" "error" "$RIP_DIR" "$error_msg" "$TITLE_COUNT" "0" "$TITLE_COUNT" "$failed_titles_json"

        log "Error file written: $RIP_DIR/error.txt"
    fi

    rm -f "$RIP_OUTPUT"
}

# ============================================================
# MAIN
# ============================================================

# Write initial status
write_status "detecting" "" "" 0 "" "Detecting disc type"

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
