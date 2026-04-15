#!/usr/bin/env bash
# ============================================================================
# gdrive-sync.sh — Robust rclone bisync for Google Drive
# ============================================================================
# Performs a bidirectional sync between a local folder and Google Drive
# using rclone bisync with proper lock handling, signal traps, and logging.
#
# Usage:
#   gdrive-sync.sh              # normal bisync
#   gdrive-sync.sh --resync     # force full resync (first run or recovery)
#
# Environment variables (with defaults):
#   GDRIVE_REMOTE       rclone remote name         (default: gdrive:)
#   GDRIVE_LOCAL        local sync folder           (default: ~/GoogleDrive-local)
#   GDRIVE_LOG_DIR      log directory               (default: ~/.local/share/gdrive-sync/logs)
#   GDRIVE_MAX_LOG_LINES  max lines kept in log     (default: 2000)
# ============================================================================
set -euo pipefail

# --- Configuration (overridable via env) ------------------------------------
REMOTE="${GDRIVE_REMOTE:-gdrive:}"
LOCAL_DIR="${GDRIVE_LOCAL:-$HOME/GoogleDrive-local}"
LOG_DIR="${GDRIVE_LOG_DIR:-$HOME/.local/share/gdrive-sync/logs}"
MAX_LOG_LINES="${GDRIVE_MAX_LOG_LINES:-2000}"

LOCKFILE="${LOG_DIR}/gdrive-sync.lock"
LOG_FILE="${LOG_DIR}/gdrive-sync.log"

# Ensure log directory exists before any log() call (including trap handlers)
mkdir -p "$LOG_DIR"

# --- Helpers ----------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >> "$LOG_FILE"
}

cleanup() {
    local exit_code=$?
    rm -f "$LOCKFILE"
    [ -n "${RCLONE_OUTPUT_TMP:-}" ] && rm -f "$RCLONE_OUTPUT_TMP"
    if [ $exit_code -ne 0 ]; then
        log "WARN" "Exited with code $exit_code — lock cleaned up"
    fi
}

notify() {
    # Desktop notification (best-effort, don't fail if notify-send is missing)
    if command -v notify-send &>/dev/null; then
        notify-send --urgency="$1" "Google Drive Sync" "$2" 2>/dev/null || true
    fi
}

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
mkdir -p "$LOCAL_DIR"

# Check rclone is available
if ! command -v rclone &>/dev/null; then
    echo "ERROR: rclone not found in PATH" >&2
    exit 1
fi

# Check remote is configured
if ! rclone listremotes 2>/dev/null | grep -qxF "${REMOTE}"; then
    log "ERROR" "rclone remote '${REMOTE}' not configured"
    exit 1
fi

# --- Lock handling (PID-based, survives crashes) ----------------------------
# Strategy: try noclobber write first (atomic). Only if that fails do we read
# the existing PID and decide whether to yield or steal a stale lock.
set -C
if ! echo $$ > "$LOCKFILE" 2>/dev/null; then
    # Lock already exists — read owner PID, strip all whitespace to avoid
    # issues with trailing newlines (fix: sanitize with tr before kill -0)
    OLD_PID=$(tr -d '[:space:]' < "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "SKIP" "Another sync is running (PID $OLD_PID)"
        exit 0
    else
        # Stale lock — owner is dead; remove and retry once
        log "WARN" "Stale lock found (PID ${OLD_PID:-unknown} dead) — removing and retrying"
        rm -f "$LOCKFILE"
        if ! echo $$ > "$LOCKFILE" 2>/dev/null; then
            OLD_PID=$(tr -d '[:space:]' < "$LOCKFILE" 2>/dev/null || echo "unknown")
            log "SKIP" "Lost lock race after stale removal (PID $OLD_PID acquired it first)"
            exit 0
        fi
    fi
fi
set +C

# TRAP: clean up lock on ANY exit (success, error, SIGTERM, SIGHUP, SIGINT)
trap cleanup EXIT

# --- Clear rclone's own stale locks ----------------------------------------
# Only remove locks whose owning PID is dead, not blindly
BISYNC_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rclone/bisync"
if [ -d "$BISYNC_CACHE_DIR" ]; then
    for lck in "$BISYNC_CACHE_DIR"/*.lck; do
        [ -f "$lck" ] || continue
        LCK_PID=$(tr -d '[:space:]' < "$lck" 2>/dev/null || echo "")
        # Validate PID is numeric — rclone lock format may change
        if ! [[ "$LCK_PID" =~ ^[0-9]+$ ]]; then
            log "WARN" "Non-numeric content in rclone lock, removing: $lck"
            rm -f "$lck"
            continue
        fi
        if [ -n "$LCK_PID" ] && kill -0 "$LCK_PID" 2>/dev/null; then
            log "INFO" "rclone bisync lock held by live PID $LCK_PID: $lck — skipping"
        else
            log "WARN" "Removing rclone bisync lock (PID ${LCK_PID:-unknown} dead): $lck"
            rm -f "$lck"
        fi
    done
fi

# --- Resync flag ------------------------------------------------------------
RCLONE_ARGS=()
if [ "${1:-}" = "--resync" ]; then
    RCLONE_ARGS=("--resync")
    log "INFO" "Resync mode requested — performing full resync"
fi

# --- Run bisync -------------------------------------------------------------
log "INFO" "Starting bisync: ${REMOTE} <-> ${LOCAL_DIR}"

# Write rclone output to a temp file to avoid buffering large syncs in RAM.
# RCLONE_OUTPUT_TMP is cleaned up by the trap's cleanup() on any exit.
RCLONE_OUTPUT_TMP=$(mktemp)
EXIT_CODE=0
rclone bisync "$REMOTE" "$LOCAL_DIR" \
    --resilient \
    --recover \
    --verbose \
    --check-access \
    --max-delete 50 \
    --conflict-resolve newer \
    --conflict-loser num \
    --conflict-suffix .gdrive-conflict \
    "${RCLONE_ARGS[@]}" \
    > "$RCLONE_OUTPUT_TMP" 2>&1 || EXIT_CODE=$?

[ -s "$RCLONE_OUTPUT_TMP" ] && cat "$RCLONE_OUTPUT_TMP" >> "$LOG_FILE"
if [ $EXIT_CODE -eq 0 ]; then
    log "OK" "Bisync completed successfully"
else
    log "ERROR" "Bisync failed with exit code $EXIT_CODE"
    notify "critical" "Sync FAILED (exit $EXIT_CODE). Check logs."
fi

# --- Rotate log -------------------------------------------------------------
rotate_log

exit $EXIT_CODE
