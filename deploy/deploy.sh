#!/bin/bash
# deploy.sh — install the mbo.optimize Omarchy plugin from this repo.
#
# What it does (all under the current user, no root needed):
#   1. Copies the plugin files into ~/.config/omarchy/plugins/mbo.optimize/
#   2. Symlinks bin/* into ~/.local/bin/ so the QML Process calls resolve
#   3. Installs the systemd --user timer for the weekly scan
#   4. Adds (idempotently) an "Optimize" entry to the Omarchy menu
#   5. Tells the shell to rescan plugins and enables the widget
#
# Usage:
#   ./deploy/deploy.sh            # full install
#   ./deploy/deploy.sh --update    # re-copy files after a git pull
#   ./deploy/deploy.sh --no-timer  # skip the systemd timer
#   ./deploy/deploy.sh --no-menu  # skip the menu entry

set -euo pipefail

PLUGIN_ID="mbo.optimize"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
LOCAL_BIN="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$PLUGINS_DIR/$PLUGIN_ID"

NO_TIMER=0
NO_MENU=0
MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) MODE="update"; shift ;;
    --no-timer) NO_TIMER=1; shift ;;
    --no-menu) NO_MENU=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

log() { printf "\033[1;34mdeploy\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31mdeploy:\033[0m %s\n" "$*" >&2; exit 1; }

command -v omarchy >/dev/null 2>&1 || fail "omarchy CLI not found — is this an Omarchy machine?"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ -d "$REPO_ROOT/bin" ]] || fail "run deploy.sh from the repo (bin/ not found at $REPO_ROOT)"

mkdir -p "$PLUGINS_DIR" "$LOCAL_BIN" "$SYSTEMD_DIR" "$(dirname "$MENU_EXT")"

# --- 1. Copy plugin files -------------------------------------------------
log "copying plugin files → $TARGET"
if [[ -e "$TARGET" && "$MODE" != "update" ]]; then
  fail "$TARGET already exists. Run with --update, or remove it first."
fi
rm -rf "$TARGET"
# Copy everything except .git and the deploy/ helper itself.
rsync -a --exclude='.git' --exclude='deploy' "$REPO_ROOT/" "$TARGET/" 2>/dev/null || {
  # Fallback if rsync is missing.
  mkdir -p "$TARGET"
  for item in "$REPO_ROOT"/*; do
    [[ -e "$item" ]] || continue
    cp -r "$item" "$TARGET/"
  done
}
log "  → copied $(find "$TARGET" -type f | wc -l) files"

# --- 2. Symlink bin scripts onto PATH -------------------------------------
log "linking bin/* → $LOCAL_BIN"
chmod +x "$TARGET"/bin/*
for bin in "$TARGET"/bin/*; do
  [[ -f "$bin" ]] || continue
  name="$(basename "$bin")"
  ln -sfn "$bin" "$LOCAL_BIN/$name"
  log "  → $name"
done

# --- 3. systemd --user timer ----------------------------------------------
if [[ $NO_TIMER -eq 0 ]]; then
  log "installing systemd user units"
  cp "$REPO_ROOT/systemd/mbo-optimize-scan.service" "$SYSTEMD_DIR/"
  cp "$REPO_ROOT/systemd/mbo-optimize-scan.timer" "$SYSTEMD_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now mbo-optimize-scan.timer
  log "  → timer enabled (Mon 09:00 weekly, Persistent=true)"
fi

# --- 4. Omarchy menu entry (idempotent) -----------------------------------
if [[ $NO_MENU -eq 0 ]]; then
  log "adding menu entry → $MENU_EXT"
  touch "$MENU_EXT"
  python3 - "$MENU_EXT" <<'PY'
import json, re, sys, os
path = sys.argv[1]
raw = open(path).read() if os.path.exists(path) else ""
# jsonc: strip // and /* */ comments before parsing.
raw_stripped = re.sub(r"//.*?$", "", raw, flags=re.M)
raw_stripped = re.sub(r"/\*.*?\*/", "", raw_stripped, flags=re.S)
try:
    data = json.loads(raw_stripped) if raw_stripped.strip() else {}
except json.JSONDecodeError:
    data = {}
if not isinstance(data, dict): data = {}
items = data.get("items", [])
if not isinstance(items, list): items = []
# Remove any prior optimize entry.
items = [i for i in items if not (isinstance(i, dict) and i.get("label","").lower().startswith("optimize"))]
items.append({
    "label": "Optimize system",
    "icon": "󰑓",
    "action": "omarchy-optimize-analyze && omarchy-shell mbo.optimize.open"
})
data["items"] = items
open(path, "w").write(json.dumps(data, indent=2))
PY
  log "  → menu entry added (label: \"Optimize system\")"
fi

# --- 5. Reload + enable plugin --------------------------------------------
log "rescanning shell plugins"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

# Wait for the registry to pick it up.
for _ in {1..40}; do
  if omarchy plugin list --json 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if any(p["id"]=="mbo.optimize" for p in json.load(sys.stdin)) else 1)'; then
    break
  fi
  sleep 0.05
done

if omarchy plugin list --json 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if any(p["id"]=="mbo.optimize" for p in json.load(sys.stdin)) else 1)'; then
  log "enabling plugin $PLUGIN_ID"
  omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || log "  → (enable skipped — enable manually with: omarchy plugin enable $PLUGIN_ID)"
else
  log "plugin not discovered yet — enable manually with: omarchy plugin enable $PLUGIN_ID"
fi

echo
log "done. state lives in ~/.local/state/omarchy/optimize/"
log "trigger a first scan:  omarchy-optimize-analyze"
log "open the panel:        omarchy-shell mbo.optimize.open"
