#!/usr/bin/env bash
# ==============================================================================
# Omarchy Network Scanner - Uninstall Script
#
# Safely removes everything the installer created:
#   - the plugin directory   (~/.config/omarchy/plugins/lu15ggtz.netscan/)
#   - the CLI wrapper        (~/.local/bin/omarchy-netscan)
#   - the bar widget entry   (~/.config/omarchy/shell.json)
#
# It does NOT touch system packages (python3, arp-scan, nmap) or revoke any
# cap_net_raw capability set on arp-scan, since those may be used elsewhere.
# ==============================================================================

set -e

PLUGIN_ID="lu15ggtz.netscan"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
CLI_BIN="$HOME/.local/bin/omarchy-netscan"

echo "==> Uninstalling Omarchy Network Scanner..."

# 1. Remove the CLI wrapper
if [ -f "$CLI_BIN" ]; then
  rm -f "$CLI_BIN"
  echo "   Removed CLI wrapper: $CLI_BIN"
else
  echo "   CLI wrapper not present, skipping."
fi

# 2. Remove the plugin directory
if [ -d "$PLUGIN_DIR" ]; then
  rm -rf "$PLUGIN_DIR"
  echo "   Removed plugin directory: $PLUGIN_DIR"
else
  echo "   Plugin directory not present, skipping."
fi

# 3. Remove the bar widget entry from shell.json (if present)
if [ -f "$SHELL_CONFIG" ]; then
  if grep -q "$PLUGIN_ID" "$SHELL_CONFIG"; then
    echo "   Removing widget entry from $SHELL_CONFIG..."
    python3 -c "
import json, sys
path = '$SHELL_CONFIG'
with open(path, 'r') as f:
    data = json.load(f)
changed = False

def strip_id(section):
    global changed
    if not isinstance(section, list):
        return section
    return [item for item in section if not (isinstance(item, dict) and item.get('id') == '$PLUGIN_ID')]

try:
    layouts = data['bar']['layout']
except (KeyError, TypeError):
    layouts = {}

for key in ('left', 'center', 'right'):
    if key in layouts:
        new_section = strip_id(layouts[key])
        if new_section != layouts[key]:
            layouts[key] = new_section
            changed = True

if changed:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print('   Widget entry removed.')
else:
    print('   Widget entry already absent, skipping.')
"
  else
    echo "   No widget entry found in $SHELL_CONFIG, skipping."
  fi
else
  echo "   $SHELL_CONFIG not present, skipping."
fi

# 4. Optional: revoke cap_net_raw from arp-scan (only if explicitly requested)
if command -v arp-scan &>/dev/null && command -v getcap &>/dev/null &&
   getcap "$(which arp-scan)" 2>/dev/null | grep -q "cap_net_raw"; then
  read -r -p "[?] Revoke cap_net_raw from arp-scan (set by this plugin's installer)? [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS])
      sudo setcap -r "$(which arp-scan)" && \
        echo "   Revoked cap_net_raw from arp-scan." || \
        echo "[!] Could not revoke cap_net_raw."
      ;;
    *)
      echo "   Leaving arp-scan capabilities unchanged (may be used elsewhere)."
      ;;
  esac
fi

echo "==> Uninstall complete. The Network Scanner widget has been removed from your Omarchy bar."
