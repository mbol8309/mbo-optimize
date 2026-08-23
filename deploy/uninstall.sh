#!/bin/bash
# uninstall.sh — remove the mbo.optimize Omarchy plugin cleanly.
set -euo pipefail

PLUGIN_ID="mbo.optimize"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
LOCAL_BIN="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
MENU_EXT="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
STATE_DIR="$HOME/.local/state/omarchy/optimize"

CONFIRM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) CONFIRM=1; shift ;;
    -h|--help) echo "Usage: $0 [-y|--yes] [--purge-state]"; exit 0 ;;
    --purge-state) PURGE_STATE=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
PURGE_STATE=${PURGE_STATE:-0}

log() { printf "\033[1;34muninstall\033[0m %s\n" "$*"; }

if [[ $CONFIRM -eq 0 ]]; then
  echo "This will remove the plugin, bin symlinks, systemd timer, and menu entry."
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
fi

log "disabling plugin"
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true

log "removing bin symlinks"
for f in omarchy-optimize-collect omarchy-optimize-analyze omarchy-optimize-apply omarchy-optimize-state; do
  [[ -L "$LOCAL_BIN/$f" ]] && rm -f "$LOCAL_BIN/$f"
done

log "removing systemd units"
systemctl --user disable --now mbo-optimize-scan.timer 2>/dev/null || true
rm -f "$SYSTEMD_DIR/mbo-optimize-scan.service" "$SYSTEMD_DIR/mbo-optimize-scan.timer"
systemctl --user daemon-reload

log "removing menu entry"
if [[ -f "$MENU_EXT" ]]; then
  python3 - "$MENU_EXT" <<'PY'
import json, re, os, sys
path = sys.argv[1]
raw = open(path).read()
raw_s = re.sub(r"//.*?$", "", raw, flags=re.M)
raw_s = re.sub(r"/\*.*?\*/", "", raw_s, flags=re.S)
try: data = json.loads(raw_s) if raw_s.strip() else {}
except: data = {}
items = data.get("items", [])
items = [i for i in items if not (isinstance(i, dict) and str(i.get("label","")).lower().startswith("optimize"))]
data["items"] = items
open(path, "w").write(json.dumps(data, indent=2))
PY
fi

log "removing plugin folder"
rm -rf "$PLUGINS_DIR/$PLUGIN_ID"
omarchy-shell shell rescanPlugins 2>/dev/null || true

if [[ "$PURGE_STATE" -eq 1 ]]; then
  log "purging state"
  rm -rf "$STATE_DIR"
else
  log "keeping state in $STATE_DIR (use --purge-state to remove)"
fi

log "done"
