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

# 3. Remove the bar widget entry from shell.json (if present).
# As in install.sh, this uses a helper that opens shell.json with O_NOFOLLOW
# (refusing a symlinked config) and writes the result atomically via a
# same-directory temp file + rename, instead of truncating it in place.
if [ -f "$SHELL_CONFIG" ]; then
  if grep -q "$PLUGIN_ID" "$SHELL_CONFIG"; then
    echo "   Removing widget entry from $SHELL_CONFIG..."
    JSON_HELPER=$(mktemp "${TMPDIR:-/tmp}/omarchy-netscan-shell-json.XXXXXX.py")
    trap 'rm -f "$JSON_HELPER"' EXIT
    cat << 'PYEOF' > "$JSON_HELPER"
import json
import os
import stat
import sys
import tempfile

path, plugin_id, mode = sys.argv[1], sys.argv[2], sys.argv[3]

# Refuse to follow a symlink at $SHELL_CONFIG -- open the real file only.
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as e:
    print(f"[!] Refusing to modify {path}: {e}", file=sys.stderr)
    sys.exit(1)

try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        print(f"[!] {path} is not a regular file; refusing to modify.", file=sys.stderr)
        sys.exit(1)
    with os.fdopen(fd, "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] Failed to read {path}: {e}", file=sys.stderr)
    sys.exit(1)

if mode != "remove":
    sys.exit(f"unknown mode: {mode}")

changed = False

def strip_id(section):
    global changed
    if not isinstance(section, list):
        return section
    new_section = [item for item in section if not (isinstance(item, dict) and item.get("id") == plugin_id)]
    if new_section != section:
        changed = True
    return new_section

try:
    layouts = data["bar"]["layout"]
except (KeyError, TypeError):
    layouts = {}

for key in ("left", "center", "right"):
    if key in layouts:
        layouts[key] = strip_id(layouts[key])

if not changed:
    print("   Widget entry already absent, skipping.")
    sys.exit(0)

# Write atomically: temp file in the same directory, fsync, then rename.
# rename() replaces whatever dentry currently sits at `path` without ever
# following it as a symlink.
dir_name = os.path.dirname(path) or "."
fd_tmp, tmp_path = tempfile.mkstemp(prefix=".shell.json.", dir=dir_name)
try:
    with os.fdopen(fd_tmp, "w") as tf:
        json.dump(data, tf, indent=2)
        tf.flush()
        os.fsync(tf.fileno())
    os.chmod(tmp_path, stat.S_IMODE(st.st_mode))
    lst = os.lstat(path)
    if stat.S_ISLNK(lst.st_mode) or lst.st_ino != st.st_ino:
        print(f"[!] {path} changed unexpectedly during update; aborting.", file=sys.stderr)
        sys.exit(1)
    os.replace(tmp_path, path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
print("   Widget entry removed.")
PYEOF
    python3 "$JSON_HELPER" "$SHELL_CONFIG" "$PLUGIN_ID" remove
    rm -f "$JSON_HELPER"
    trap - EXIT
  else
    echo "   No widget entry found in $SHELL_CONFIG, skipping."
  fi
else
  echo "   $SHELL_CONFIG not present, skipping."
fi

# 4. Optional: revoke cap_net_raw from arp-scan (only if explicitly requested).
# Resolve to a canonical, symlink-free path first so we never act on a
# same-named binary shadowing arp-scan elsewhere on $PATH.
if command -v arp-scan &>/dev/null && command -v getcap &>/dev/null; then
  ARP_SCAN_REAL=$(readlink -f -- "$(command -v arp-scan)" 2>/dev/null) || ARP_SCAN_REAL=""
  case "$ARP_SCAN_REAL" in
    /usr/bin/arp-scan|/usr/sbin/arp-scan) ;;
    *) ARP_SCAN_REAL="" ;;
  esac

  if [ -n "$ARP_SCAN_REAL" ] && getcap "$ARP_SCAN_REAL" 2>/dev/null | grep -q "cap_net_raw"; then
    read -r -p "[?] Revoke cap_net_raw from arp-scan (set by this plugin's installer)? [y/N] " ans
    case "$ans" in
      [yY]|[yY][eE][sS])
        sudo setcap -r "$ARP_SCAN_REAL" && \
          echo "   Revoked cap_net_raw from arp-scan." || \
          echo "[!] Could not revoke cap_net_raw."
        ;;
      *)
        echo "   Leaving arp-scan capabilities unchanged (may be used elsewhere)."
        ;;
    esac
  fi
fi

echo "==> Uninstall complete. The Network Scanner widget has been removed from your Omarchy bar."
