#!/usr/bin/env bash
# ============================================================================
# gdrive-watcher.sh — inotifywait watcher that triggers bisync on changes
# ============================================================================
# Watches the local Google Drive folder for file changes (create, modify,
# delete, move) and triggers a debounced bisync after activity settles.
#
# This script runs as a long-lived daemon (Type=simple in systemd).
# It calls gdrive-sync.sh for the actual sync, which handles its own locking.
#
# Environment variables (with defaults):
#   GDRIVE_LOCAL         local sync folder           (default: ~/GoogleDrive-local)
#   GDRIVE_DEBOUNCE_SEC  seconds to wait after last  (default: 30)
#                        change before syncing
#   GDRIVE_SYNC_SCRIPT   path to gdrive-sync.sh      (default: ~/.local/bin/gdrive-sync.sh)
#   GDRIVE_LOG_DIR       log directory                (default: ~/.local/share/gdrive-sync/logs)
# ============================================================================
# NOTE: -e (errexit) is intentionally NOT set here.
# This script runs a permanent `while true` loop where non-zero exit codes are
# normal and expected: inotifywait returns 1 on timeout (debounce), and
# gdrive-sync.sh returns non-zero on sync errors. Adding -e would kill the
# watcher on the first timeout or transient sync failure, which is wrong.
set -uo pipefail

# --- Configuration ----------------------------------------------------------
LOCAL_DIR="${GDRIVE_LOCAL:-$HOME/GoogleDrive-local}"
DEBOUNCE_SEC="${GDRIVE_DEBOUNCE_SEC:-30}"
SYNC_SCRIPT="${GDRIVE_SYNC_SCRIPT:-$HOME/.local/bin/gdrive-sync.sh}"
LOG_DIR="${GDRIVE_LOG_DIR:-$HOME/.local/share/gdrive-sync/logs}"
LOG_FILE="${LOG_DIR}/gdrive-watcher.log"
MAX_LOG_LINES="${GDRIVE_MAX_LOG_LINES:-1000}"

# --- Helpers ----------------------------------------------------------------
# LOG_DIR must exist before any log() call, including the DEBOUNCE guard below
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"
}

# Guard against division-by-zero in MAX_DEBOUNCE_CYCLES calculation:
# DEBOUNCE_SEC must be >= 1
if [ "$DEBOUNCE_SEC" -lt 1 ] 2>/dev/null; then
    DEBOUNCE_SEC=30
    log "WARN" "Invalid DEBOUNCE_SEC, defaulting to 30"
fi

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local lines
        lines=$(wc -l < "$LOG_FILE")
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# --- Pre-flight checks ------------------------------------------------------
if ! command -v inotifywait &>/dev/null; then
    log "ERROR" "inotifywait not found. Install inotify-tools with your package manager."
    echo "ERROR: inotifywait not found. Install inotify-tools with your package manager." >&2
    exit 1
fi

if [ ! -x "$SYNC_SCRIPT" ]; then
    log "ERROR" "Sync script not found or not executable: $SYNC_SCRIPT"
    echo "ERROR: Sync script not found or not executable: $SYNC_SCRIPT" >&2
    exit 1
fi

if [ ! -d "$LOCAL_DIR" ]; then
    log "ERROR" "Local directory does not exist: $LOCAL_DIR"
    echo "ERROR: Local directory does not exist: $LOCAL_DIR" >&2
    exit 1
fi

# --- Watcher loop -----------------------------------------------------------
log "INFO" "Watcher started — monitoring: $LOCAL_DIR (debounce: ${DEBOUNCE_SEC}s)"

# Patterns to ignore (rclone temp files, editor swap files, OS junk)
# Also exclude rclone's own temp files (.rclonepart, .rclone) to prevent
# a sync triggering another sync (sync-triggering-sync loop).
EXCLUDE_PATTERN='(\.partial~$|\.swp$|\.swx$|~$|\.tmp$|\.crdownload$|\/4913$|\.rclonepart$)'

MAX_DEBOUNCE_CYCLES=$(( 300 / DEBOUNCE_SEC > 0 ? 300 / DEBOUNCE_SEC : 1 ))

while true; do
    # Wait for filesystem events (blocks until something happens)
    # --recursive: watch subdirectories
    # --timeout 3600: health-check hourly; exit code 2 = timeout (loop continues)
    # -e: events that indicate real content changes
    INOTIFY_EXIT=0
    inotifywait \
        --recursive \
        --quiet \
        --timeout 3600 \
        --event modify,create,delete,move \
        --exclude "$EXCLUDE_PATTERN" \
        "$LOCAL_DIR" 2>>"$LOG_FILE" || INOTIFY_EXIT=$?
    # Exit code 2 = inotifywait timeout (no events) — loop back and re-watch
    if [ $INOTIFY_EXIT -eq 2 ]; then
        continue
    fi
    if [ $INOTIFY_EXIT -ne 0 ]; then
        # inotifywait can exit on error (e.g. max watches exceeded)
        log "WARN" "inotifywait exited (code $INOTIFY_EXIT), restarting in 10s..."
        sleep 10
        continue
    fi

    log "INFO" "Change detected — waiting ${DEBOUNCE_SEC}s for activity to settle..."

    # Debounce: keep resetting the timer while changes keep coming
    # Cap at MAX_DEBOUNCE_CYCLES (~5 minutes) to prevent indefinite delay
    debounce_count=0
    while [ $debounce_count -lt $MAX_DEBOUNCE_CYCLES ] && inotifywait \
        --recursive \
        --quiet \
        --timeout "$DEBOUNCE_SEC" \
        --event modify,create,delete,move \
        --exclude "$EXCLUDE_PATTERN" \
        "$LOCAL_DIR" 2>>"$LOG_FILE"; do
        debounce_count=$(( debounce_count + 1 ))
        log "DEBUG" "More changes detected — resetting debounce timer ($debounce_count/$MAX_DEBOUNCE_CYCLES)"
    done
    if [ $debounce_count -ge $MAX_DEBOUNCE_CYCLES ]; then
        log "WARN" "Debounce ceiling reached (${MAX_DEBOUNCE_CYCLES} cycles) — forcing sync"
    fi

    log "INFO" "Activity settled — triggering sync"

    # Run sync (it handles its own locking, so concurrent calls are safe)
    SYNC_EXIT=0
    "$SYNC_SCRIPT" || SYNC_EXIT=$?
    if [ $SYNC_EXIT -eq 0 ]; then
        log "OK" "Sync completed after file change"
    else
        log "ERROR" "Sync failed after file change (exit $SYNC_EXIT)"
    fi

    rotate_log
done
