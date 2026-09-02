#!/usr/bin/env bash
# ==============================================================================
# Omarchy Network Scanner - Installation Script
# ==============================================================================

set -e

PLUGIN_ID="lu15ggtz.netscan"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_CONFIG="$HOME/.config/omarchy/shell.json"

echo "==> Installing Omarchy Network Scanner..."

# 1. Check system dependencies
echo "==> Checking dependencies..."
MISSING_DEPS=()
for dep in python3 arp-scan nmap; do
  if ! command -v "$dep" &>/dev/null; then
    MISSING_DEPS+=("$dep")
  fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo "[!] Missing required tools: ${MISSING_DEPS[*]}"
  echo "    Please install them on Arch/Omarchy via:"
  echo "    sudo pacman -S ${MISSING_DEPS[*]}"
  exit 1
fi

# Optional: grant arp-scan raw packet capabilities for unprivileged scanning.
# This modifies a system-wide binary with root, so it is opt-in, requires
# explicit confirmation, AND is only ever applied to a binary we can prove is
# the real, unmodified, pacman-owned /usr/bin/arp-scan -- never merely
# whatever "arp-scan" happens to resolve to first on $PATH. If skipped, the
# plugin falls back to running arp-scan with whatever privileges are
# available (and README documents an alternative).
#
# Verification performed before ever calling `sudo setcap`, in order:
#   1. Resolve the PATH hit to its canonical, symlink-free real path.
#   2. Require that path to be exactly /usr/bin/arp-scan or /usr/sbin/arp-scan
#      (rejects AUR-into-~/.local/bin shadowing, /tmp shadowing, etc.).
#   3. Require it to be a regular file, owned by root, not group/other
#      writable (rejects a tampered or attacker-writable binary).
#   4. Require pacman to confirm that exact path is owned by the arp-scan
#      package and that the package's file-integrity check passes (rejects
#      a binary that isn't what the distro shipped, even if steps 1-3 pass).
# Any failure aborts the setcap step entirely -- we never fall back to a
# weaker check.
try_setcap_arpscan() {
  if ! command -v setcap &>/dev/null || ! command -v arp-scan &>/dev/null; then
    return
  fi

  local path_hit real_path owner_uid perm_octal perm_dec owning_pkg

  path_hit=$(command -v arp-scan)
  if ! real_path=$(readlink -f -- "$path_hit" 2>/dev/null) || [ -z "$real_path" ]; then
    echo "[!] Could not resolve a canonical path for arp-scan; skipping cap_net_raw setup."
    return
  fi

  case "$real_path" in
    /usr/bin/arp-scan|/usr/sbin/arp-scan) ;;
    *)
      echo "[!] arp-scan resolved to a non-standard path ($real_path);"
      echo "    refusing to grant cap_net_raw. Run arp-scan with sudo instead."
      return
      ;;
  esac

  if [ ! -f "$real_path" ] || [ -L "$real_path" ]; then
    echo "[!] $real_path is not a plain regular file; refusing to grant cap_net_raw."
    return
  fi

  owner_uid=$(stat -c '%u' "$real_path" 2>/dev/null) || owner_uid=""
  perm_octal=$(stat -c '%a' "$real_path" 2>/dev/null) || perm_octal=""
  if [ "$owner_uid" != "0" ] || [ -z "$perm_octal" ]; then
    echo "[!] $real_path is not owned by root; refusing to grant cap_net_raw."
    return
  fi
  perm_dec=$((8#$perm_octal))
  if (( perm_dec & 0022 )); then
    echo "[!] $real_path is group/other-writable (mode $perm_octal); refusing to grant cap_net_raw."
    return
  fi

  if ! command -v pacman &>/dev/null; then
    echo "[!] pacman not found, cannot verify arp-scan's package provenance;"
    echo "    skipping cap_net_raw setup for safety."
    return
  fi

  owning_pkg=$(pacman -Qqo "$real_path" 2>/dev/null) || owning_pkg=""
  if [ "$owning_pkg" != "arp-scan" ]; then
    echo "[!] $real_path is not owned by the arp-scan package (owner: '${owning_pkg:-none}');"
    echo "    refusing to grant cap_net_raw."
    return
  fi
  if ! pacman -Qkk arp-scan >/dev/null 2>&1; then
    echo "[!] arp-scan package files failed pacman's integrity check;"
    echo "    refusing to grant cap_net_raw."
    return
  fi

  if getcap "$real_path" 2>/dev/null | grep -q "cap_net_raw"; then
    echo "[*] arp-scan already has cap_net_raw."
    return
  fi

  read -r -p "[?] Grant cap_net_raw to arp-scan for unprivileged scanning? [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS])
      echo "[*] Setting capabilities on arp-scan for unprivileged scanning..."
      sudo setcap cap_net_raw+p "$real_path" || \
        echo "[!] Unable to set cap_net_raw (you may need to run arp-scan with sudo instead)."
      ;;
    *)
      echo "[*] Skipping cap_net_raw setup. arp-scan may require sudo to scan."
      ;;
  esac
}

try_setcap_arpscan

# 2. Create plugin destination directory
mkdir -p "$PLUGIN_DIR"
mkdir -p "$HOME/.local/bin"

# 3. Copy plugin files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR/manifest.json" "$PLUGIN_DIR/"
cp -r "$SCRIPT_DIR/Panel.qml" "$PLUGIN_DIR/"
cp -r "$SCRIPT_DIR/bin" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/bin/netscan-engine"

# 4. Install CLI trigger wrapper
cat << 'EOF' > "$HOME/.local/bin/omarchy-netscan"
#!/usr/bin/env bash
PLUGIN_ID="lu15ggtz.netscan"
ENGINE="$HOME/.config/omarchy/plugins/lu15ggtz.netscan/bin/netscan-engine"

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
  echo "Omarchy Network Scanner"
  echo "======================="
  echo "Usage:"
  echo "  omarchy-netscan             Toggle the floating Network Scanner panel in Omarchy bar"
  echo "  omarchy-netscan --cli       Run fast ARP network discovery in terminal"
  echo "  omarchy-netscan --ports IP  Scan open ports on a specific IP in terminal"
  exit 0
fi

if [ "$1" == "--cli" ]; then
  python3 "$ENGINE" scan | python3 -m json.tool
  exit 0
fi

if [ "$1" == "--ports" ]; then
  if [ -z "$2" ]; then
    echo "Error: Please specify target IP (e.g. omarchy-netscan --ports 192.168.100.1)"
    exit 1
  fi
  python3 "$ENGINE" ports "$2" | python3 -m json.tool
  exit 0
fi

if command -v omarchy-shell &>/dev/null; then
  omarchy-shell shell toggle "$PLUGIN_ID"
else
  python3 "$ENGINE" scan | python3 -m json.tool
fi
EOF
chmod +x "$HOME/.local/bin/omarchy-netscan"

# 5. Optionally enable in shell.json (only with explicit user consent).
# We never modify the user's bar configuration without confirmation, and the
# mutation itself is safe against a symlink/TOCTOU attack on shell.json: the
# helper script opens the file with O_NOFOLLOW (refusing if it's a symlink),
# then writes the result to a temp file in the same directory and atomically
# renames it into place, instead of truncating shell.json in place.
if [ -f "$SHELL_CONFIG" ]; then
  if ! grep -q "$PLUGIN_ID" "$SHELL_CONFIG"; then
    read -r -p "[?] Add Network Scanner to your Omarchy bar ($SHELL_CONFIG)? [Y/n] " ans
    case "$ans" in
      [nN]|[nN][oO])
        echo "[*] Skipping shell.json changes. You can add it later via"
        echo "    omarchy plugin enable lu15ggtz.netscan or by editing $SHELL_CONFIG manually."
        ;;
      *)
        echo "[*] Adding widget to $SHELL_CONFIG..."
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

right_layout = data.setdefault("bar", {}).setdefault("layout", {}).setdefault("right", [])
if mode == "add":
    if any(item.get("id") == plugin_id for item in right_layout):
        sys.exit(0)
    net_idx = -1
    for i, item in enumerate(right_layout):
        if item.get("id") == "omarchy.network":
            net_idx = i
            break
    if net_idx != -1:
        right_layout.insert(net_idx + 1, {"id": plugin_id})
    else:
        right_layout.append({"id": plugin_id})
else:
    sys.exit(f"unknown mode: {mode}")

# Write atomically: temp file in the same directory, fsync, then rename.
# rename() replaces whatever dentry currently sits at `path` without ever
# following it as a symlink, so this can't be tricked into clobbering an
# arbitrary target even if `path` were swapped for a symlink mid-run.
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
print("[*] shell.json updated.")
PYEOF
        python3 "$JSON_HELPER" "$SHELL_CONFIG" "$PLUGIN_ID" add
        rm -f "$JSON_HELPER"
        trap - EXIT
        ;;
    esac
  fi
fi

echo "==> Installation complete!"
if grep -q "$PLUGIN_ID" "$SHELL_CONFIG" 2>/dev/null; then
  echo "    The Network Scanner icon is now available on your Omarchy bar."
else
  echo "    Enable it later on your bar with:  omarchy plugin enable lu15ggtz.netscan"
fi
