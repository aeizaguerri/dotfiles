#!/usr/bin/env bash
# ============================================================================
# install.sh — Installs gdrive-sync scripts and systemd services
# ============================================================================
# What it does:
#   1. Checks dependencies (rclone, inotifywait)
#   2. Removes old cron job and stale locks if they exist
#   3. Copies scripts to ~/.local/bin/
#   4. Copies systemd units to ~/.config/systemd/user/
#   5. Creates RCLONE_TEST file for --check-access
#   6. Enables and starts the services
#
# Usage:
#   ./install.sh              # install and enable
#   ./install.sh --uninstall  # stop, disable, remove everything
# ============================================================================
set -euo pipefail

# --- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
LOG_DIR="$HOME/.local/share/gdrive-sync/logs"
LOCAL_DIR="$HOME/GoogleDrive-local"
REMOTE="${GDRIVE_REMOTE:-gdrive:}"

# ============================================================================
# UNINSTALL
# ============================================================================
if [ "${1:-}" = "--uninstall" ]; then
    echo ""
    info "Uninstalling gdrive-sync..."
    echo ""

    # Stop and disable services
    systemctl --user stop gdrive-sync-watcher.service 2>/dev/null && ok "Stopped watcher" || true
    systemctl --user stop gdrive-sync-boot.service 2>/dev/null && ok "Stopped boot sync" || true
    systemctl --user disable gdrive-sync-watcher.service 2>/dev/null && ok "Disabled watcher" || true
    systemctl --user disable gdrive-sync-boot.service 2>/dev/null && ok "Disabled boot sync" || true

    # Remove files
    rm -f "$BIN_DIR/gdrive-sync.sh" && ok "Removed $BIN_DIR/gdrive-sync.sh" || true
    rm -f "$BIN_DIR/gdrive-watcher.sh" && ok "Removed $BIN_DIR/gdrive-watcher.sh" || true
    rm -f "$SYSTEMD_DIR/gdrive-sync-boot.service" && ok "Removed boot service" || true
    rm -f "$SYSTEMD_DIR/gdrive-sync-watcher.service" && ok "Removed watcher service" || true

    systemctl --user daemon-reload

    echo ""
    ok "Uninstall complete. Logs preserved in $LOG_DIR"
    warn "Local folder $LOCAL_DIR was NOT removed (your files are safe)"
    echo ""
    exit 0
fi

# ============================================================================
# INSTALL
# ============================================================================
echo ""
echo "=========================================="
echo "  gdrive-sync installer"
echo "=========================================="
echo ""

# --- Step 1: Check dependencies ---------------------------------------------
info "Checking dependencies..."

DEPS_OK=true
if command -v rclone &>/dev/null; then
    ok "rclone $(rclone version 2>/dev/null | head -1)"
else
    error "rclone not found. Install it with your package manager (e.g. dnf, apt, brew)."
    DEPS_OK=false
fi

if command -v inotifywait &>/dev/null; then
    ok "inotifywait found"
else
    error "inotifywait not found. Install inotify-tools with your package manager."
    DEPS_OK=false
fi

if command -v notify-send &>/dev/null; then
    ok "notify-send found (desktop notifications enabled)"
else
    warn "notify-send not found — desktop notifications will be skipped"
fi

if ! rclone listremotes 2>/dev/null | grep -qxF "${REMOTE}"; then
    error "rclone remote '${REMOTE}' not configured. Run: rclone config"
    DEPS_OK=false
else
    ok "rclone remote '${REMOTE}' configured"
fi

if [ "$DEPS_OK" = false ]; then
    echo ""
    error "Missing dependencies. Fix the issues above and re-run."
    exit 1
fi

echo ""

# --- Step 2: Clean up old setup ---------------------------------------------
info "Cleaning up old setup..."

# Remove old cron job (only if crontab -l succeeds and has matching entries)
# Use mktemp to avoid predictable-path symlink attacks on /tmp
CRON_BACKUP=$(mktemp)
if crontab -l > "$CRON_BACKUP" 2>/dev/null; then
    if grep -q "gdrive_sync\|gdrive-sync" "$CRON_BACKUP"; then
        grep -v "gdrive_sync\|gdrive-sync" "$CRON_BACKUP" | crontab -
        ok "Removed old cron job"
    else
        ok "No old cron job found"
    fi
else
    ok "No crontab found — nothing to clean up"
fi
rm -f "$CRON_BACKUP"

# Remove old script
if [ -f "$HOME/.local/bin/gdrive_sync.sh" ]; then
    rm -f "$HOME/.local/bin/gdrive_sync.sh"
    ok "Removed old script: ~/.local/bin/gdrive_sync.sh"
fi

# Remove stale app lock
if [ -f "$HOME/.logs/rclone/sync.lock" ]; then
    rm -f "$HOME/.logs/rclone/sync.lock"
    ok "Removed stale app lock"
fi

# Remove stale rclone bisync locks — only if the owning PID is dead
shopt -s nullglob
for lck in "$HOME/.cache/rclone/bisync"/*.lck; do
    LCK_PID=$(tr -d '[:space:]' < "$lck" 2>/dev/null || echo "")
    if [ -n "$LCK_PID" ] && kill -0 "$LCK_PID" 2>/dev/null; then
        warn "rclone bisync lock held by live PID $LCK_PID: $lck — skipping"
    else
        rm -f "$lck"
        ok "Removed stale rclone lock: $lck"
    fi
done
shopt -u nullglob

echo ""

# --- Step 3: Create directories ---------------------------------------------
info "Creating directories..."
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR" "$LOG_DIR" "$LOCAL_DIR"
ok "Directories ready"

echo ""

# --- Step 4: Copy scripts ---------------------------------------------------
info "Installing scripts..."

cp "$SCRIPT_DIR/gdrive-sync.sh" "$BIN_DIR/gdrive-sync.sh"
chmod +x "$BIN_DIR/gdrive-sync.sh"
ok "Installed $BIN_DIR/gdrive-sync.sh"

cp "$SCRIPT_DIR/gdrive-watcher.sh" "$BIN_DIR/gdrive-watcher.sh"
chmod +x "$BIN_DIR/gdrive-watcher.sh"
ok "Installed $BIN_DIR/gdrive-watcher.sh"

echo ""

# --- Step 5: Create RCLONE_TEST for --check-access --------------------------
info "Setting up rclone --check-access marker..."

RCLONE_TEST_LOCAL="$LOCAL_DIR/RCLONE_TEST"
if [ ! -f "$RCLONE_TEST_LOCAL" ]; then
    echo "bisync check access marker — do not delete" > "$RCLONE_TEST_LOCAL"
    ok "Created $RCLONE_TEST_LOCAL"

    # Also upload to remote if not present
    if ! rclone lsf "$REMOTE" 2>/dev/null | grep -q "^RCLONE_TEST$"; then
        if rclone copyto "$RCLONE_TEST_LOCAL" "${REMOTE}RCLONE_TEST" 2>/dev/null; then
            ok "Uploaded RCLONE_TEST to ${REMOTE}"
        else
            warn "Could not upload RCLONE_TEST — check connectivity; bisync --check-access may fail"
        fi
    else
        ok "RCLONE_TEST already exists on remote"
    fi
else
    ok "RCLONE_TEST already exists locally"
fi

echo ""

# --- Step 6: Initial resync if needed ---------------------------------------
info "Checking if bisync needs initial resync..."

BISYNC_CACHE="$HOME/.cache/rclone/bisync"

# Check for both required listing files that bisync creates
# Check for both required listing files using nullglob (ls+grep is fragile)
BISYNC_NEEDS_RESYNC=false
shopt -s nullglob
path1_files=("$BISYNC_CACHE"/*path1.lst)
path2_files=("$BISYNC_CACHE"/*path2.lst)
shopt -u nullglob
if [ ${#path1_files[@]} -eq 0 ] || [ ${#path2_files[@]} -eq 0 ]; then
    BISYNC_NEEDS_RESYNC=true
fi

if [ "$BISYNC_NEEDS_RESYNC" = true ]; then
    warn "No bisync listing files found — running initial --resync"
    warn "This may take a minute..."
    if "$BIN_DIR/gdrive-sync.sh" --resync; then
        ok "Initial resync completed successfully"
    else
        error "Initial resync failed. Check: $LOG_DIR/gdrive-sync.log"
        error "Fix the issue and re-run, or retry manually: gdrive-sync.sh --resync"
        exit 1
    fi
else
    ok "Bisync listing files (path1.lst + path2.lst) exist — skipping initial resync"
fi

echo ""

# --- Step 7: Install systemd services ---------------------------------------
info "Installing systemd services..."

cp "$SCRIPT_DIR/systemd/gdrive-sync-boot.service" "$SYSTEMD_DIR/"
ok "Installed gdrive-sync-boot.service"

cp "$SCRIPT_DIR/systemd/gdrive-sync-watcher.service" "$SYSTEMD_DIR/"
ok "Installed gdrive-sync-watcher.service"

systemctl --user daemon-reload
ok "Systemd daemon reloaded"

echo ""

# --- Step 8: Enable and start services --------------------------------------
info "Enabling and starting services..."

systemctl --user enable gdrive-sync-boot.service
ok "Enabled gdrive-sync-boot.service (will run on login)"

systemctl --user enable --now gdrive-sync-watcher.service
ok "Enabled and started gdrive-sync-watcher.service"

# Ensure user services run even when not logged in (linger)
if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "yes"; then
    warn "Enabling lingering so services run at boot even before login"
    loginctl enable-linger "$USER" 2>/dev/null || warn "Could not enable linger (may need sudo)"
fi

echo ""

# --- Done! ------------------------------------------------------------------
echo "=========================================="
echo -e "  ${GREEN}Installation complete!${NC}"
echo "=========================================="
echo ""
echo "  Services:"
echo "    gdrive-sync-boot.service    → syncs on login"
echo "    gdrive-sync-watcher.service → syncs on file changes"
echo ""
echo "  Useful commands:"
echo "    gdrive-sync.sh              → manual sync"
echo "    gdrive-sync.sh --resync     → force full resync"
echo "    systemctl --user status gdrive-sync-watcher"
echo "    journalctl --user -u gdrive-sync-watcher -f"
echo "    cat $LOG_DIR/gdrive-sync.log"
echo "    cat $LOG_DIR/gdrive-watcher.log"
echo ""
echo "  Uninstall:"
echo "    ./install.sh --uninstall"
echo ""
