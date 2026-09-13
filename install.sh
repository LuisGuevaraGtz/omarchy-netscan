#!/usr/bin/env bash
# ==============================================================================
# Omarchy Network Scanner - Installation Script
#
# Path-aware and distro-agnostic:
#   * Honors $XDG_CONFIG_HOME instead of assuming ~/.config, and every artifact
#     it writes (CLI wrapper, systemd unit) is generated from the resolved
#     plugin path -- so the watch timer keeps working no matter where the user
#     keeps their Omarchy config.
#   * Never fails hard on missing optional tools. python3 is the only hard
#     requirement; without arp-scan the engine falls back to the kernel
#     neighbor table, and without nmap the port-scan buttons report it
#     cleanly. This keeps non-Arch users unblocked.
#   * Every privileged or persistent change (cap_net_raw on arp-scan, the
#     systemd --user timer, the shell.json bar entry) stays opt-in and asks
#     for explicit confirmation before doing anything.
# ==============================================================================

set -e

PLUGIN_ID="lu15ggtz.netscan"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
OMARCHY_CONFIG="$XDG_CONFIG_HOME/omarchy"
PLUGIN_DIR="$OMARCHY_CONFIG/plugins/$PLUGIN_ID"
SHELL_CONFIG="$OMARCHY_CONFIG/shell.json"
CLI_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$XDG_CONFIG_HOME/systemd/user"

echo "==> Installing Omarchy Network Scanner..."
echo "    Plugin dir : $PLUGIN_DIR"
echo "    Shell conf : $SHELL_CONFIG"
echo "    CLI wrapper: $CLI_DIR/omarchy-netscan"

# 1. Check system dependencies (advisory except for python3).
echo "==> Checking dependencies..."
if ! command -v python3 &>/dev/null; then
  echo "[!] python3 is required (the engine is a Python script)."
  echo "    Install it with your system package manager and re-run this script."
  exit 1
fi

# Resolve the deterministic interpreter baked into the CLI wrapper and the
# systemd unit: an absolute, symlink-free path in a distro-managed bin
# directory, pointing at a root-owned, non-group/other-writable, executable
# regular file. This is the same trust bar the engine itself applies to its
# helpers at runtime (see _trusted_bin in bin/netscan-engine) -- the engine
# must never be started through a PATH-resolved `python3`.
PYTHON_BIN="$(realpath "$(command -v python3)")"
case "$PYTHON_BIN" in
  /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*) ;;
  *) echo "[!] python3 resolves to '$PYTHON_BIN', outside the distro-managed bin directories."; exit 1;;
esac
if [ ! -f "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ] || [ -n "$(find "$PYTHON_BIN" -maxdepth 0 \( -not -uid 0 -or -perm /022 \))" ]; then
  echo "[!] python3 at '$PYTHON_BIN' is not a root-owned, non-group/other-writable executable file."
  exit 1
fi

MISSING_DEPS=()
for dep in arp-scan nmap; do
  if ! command -v "$dep" &>/dev/null; then
    MISSING_DEPS+=("$dep")
  fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo "[!] Optional tools not found: ${MISSING_DEPS[*]}"
  echo "    Install them with your system package manager to unlock their feature:"
  echo "      Arch/Omarchy:  sudo pacman -S ${MISSING_DEPS[*]}"
  echo "      Debian/Ubuntu: sudo apt install ${MISSING_DEPS[*]}"
  echo "      Fedora:        sudo dnf install ${MISSING_DEPS[*]}"
  echo
  echo "    Without them the plugin still works, with reduced scope:"
  echo "      - arp-scan: misses out on fast raw-packet scanning and vendor OUI;"
  echo "                  the panel uses the kernel neighbor table instead."
  echo "      - nmap:     the 'Scan' and 'Deep' buttons report 'nmap binary not"
  echo "                  found' instead of probing ports."
fi

# Optional: grant arp-scan raw packet capabilities for unprivileged scanning.
# This modifies a system-wide binary with root, so it is opt-in, requires
# explicit confirmation, AND is only ever applied to a binary we can prove is
# the real, unmodified, pacman-owned /usr/bin/arp-scan -- never merely
# whatever "arp-scan" happens to resolve to first on $PATH. If skipped, the
# plugin falls back to running arp-scan with whatever privileges are
# available (and README documents an alternative). On distros without pacman
# the provenance check cannot be performed, so the step is skipped entirely
# rather than weakening the check.
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
mkdir -p "$CLI_DIR"

# 3. Copy plugin files (never the interpreter's bytecode cache).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR/manifest.json" "$PLUGIN_DIR/"
cp -r "$SCRIPT_DIR/Panel.qml" "$PLUGIN_DIR/"
cp -r "$SCRIPT_DIR/bin" "$PLUGIN_DIR/"
rm -rf "$PLUGIN_DIR/bin/__pycache__"
chmod +x "$PLUGIN_DIR/bin/netscan-engine"

# 4. Install CLI trigger wrapper. Generated from the resolved plugin path so
#    it keeps working when $XDG_CONFIG_HOME points somewhere non-standard.
#    @PLUGIN_ID@ / @ENGINE@ / @PYTHON@ are substituted below; every other '$'
#    is written literally for the wrapper's own runtime use.
cat << 'WRAPPER_EOF' > "$CLI_DIR/omarchy-netscan"
#!/usr/bin/env bash
PLUGIN_ID="@PLUGIN_ID@"
ENGINE="@ENGINE@"
PYTHON="@PYTHON@"

# Run the engine with a deterministic interpreter (/usr/bin/python3 -IS:
# absolute path, isolated mode, no site processing) and a scrubbed
# environment. env -i drops everything the caller's shell exported --
# PYTHON*, LD_PRELOAD/LD_LIBRARY_PATH included -- then only the values
# the engine and its helpers need are passed back in. Empty values fall
# back to the engine's own defaults (e.g. ~/.config when XDG_* is empty).
_engine() {
  env -i \
    "HOME=$HOME" \
    "XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-}" \
    "XDG_STATE_HOME=${XDG_STATE_HOME:-}" \
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" \
    "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" \
    "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}" \
    "PATH=/usr/bin:/usr/sbin:/bin:/sbin" \
    "LC_ALL=C" \
    "$PYTHON" -I -S "$ENGINE" "$@"
}

_json() {
  "$PYTHON" -I -S -m json.tool
}

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
  echo "Omarchy Network Scanner"
  echo "======================="
  echo "Usage:"
  echo "  omarchy-netscan                  Toggle the floating Network Scanner panel in Omarchy bar"
  echo "  omarchy-netscan --cli            Run fast ARP network discovery in terminal"
  echo "  omarchy-netscan --ports IP       Scan open ports on a specific IP in terminal"
  echo "  omarchy-netscan --watch on       Enable the periodic background snapshot timer"
  echo "  omarchy-netscan --watch off      Disable it"
  echo "  omarchy-netscan --watch status   Show whether it's enabled/running"
  echo
  echo "The watch timer runs 'netscan-engine snapshot' every ~15 minutes via a"
  echo "systemd --user timer; it notifies about newly seen devices and leaves"
  echo "nothing running between runs. It's opt-in -- see install.sh."
  exit 0
fi

if [ "$1" == "--cli" ]; then
  _engine scan | _json
  exit 0
fi

if [ "$1" == "--ports" ]; then
  if [ -z "$2" ]; then
    echo "Error: Please specify target IP (e.g. omarchy-netscan --ports 192.168.100.1)"
    exit 1
  fi
  _engine ports "$2" | _json
  exit 0
fi

if [ "$1" == "--watch" ]; then
  if ! command -v systemctl &>/dev/null; then
    echo "Error: systemctl not found; the watch timer needs systemd --user."
    exit 1
  fi
  case "$2" in
    on)
      systemctl --user enable --now omarchy-netscan.timer && \
        echo "Watch timer enabled (runs every ~15 minutes)."
      ;;
    off)
      systemctl --user disable --now omarchy-netscan.timer && \
        echo "Watch timer disabled."
      ;;
    status)
      systemctl --user status omarchy-netscan.timer --no-pager
      ;;
    *)
      echo "Usage: omarchy-netscan --watch on|off|status"
      exit 1
      ;;
  esac
  exit 0
fi

if command -v omarchy-shell &>/dev/null; then
  omarchy-shell shell toggle "$PLUGIN_ID"
else
  _engine scan | _json
fi
WRAPPER_EOF
sed -i -e "s|@PLUGIN_ID@|$PLUGIN_ID|g" -e "s|@ENGINE@|$PLUGIN_DIR/bin/netscan-engine|g" -e "s|@PYTHON@|$PYTHON_BIN|g" "$CLI_DIR/omarchy-netscan"
chmod +x "$CLI_DIR/omarchy-netscan"

# 5. Install the (opt-in) systemd --user units for periodic snapshots /
# new-device notifications. Units are generated from the resolved plugin
# path (rather than shipped as static files) so the timer finds the engine
# even when $XDG_CONFIG_HOME is non-standard. Installing the unit files is
# harmless on its own -- nothing runs until the timer is enabled, which we
# only do with explicit confirmation, same as setcap and shell.json above.
# Default: no.
mkdir -p "$SYSTEMD_USER_DIR"

cat << 'SERVICE_EOF' > "$SYSTEMD_USER_DIR/omarchy-netscan.service"
[Unit]
Description=Omarchy netscan snapshot

[Service]
Type=oneshot
ExecStart=@PYTHON@ -I -S @ENGINE@ snapshot
PrivateTmp=yes
# Deterministic locale and helper lookup for the run.
Environment=LC_ALL=C PATH=/usr/bin:/usr/sbin:/bin:/sbin
# The engine is launched as an absolute interpreter with -IS (isolated, no
# site processing) and binds every helper to a verified absolute path, but
# belt and suspenders: drop interpreter/startup and loader-injection
# variables from the unit's environment as well.
UnsetEnvironment=PYTHONPATH PYTHONHOME PYTHONSTARTUP LD_PRELOAD LD_LIBRARY_PATH

# Deliberately NOT setting NoNewPrivileges=yes: it would block file
# capabilities from taking effect, and arp-scan needs its cap_net_raw+p
# (granted, opt-in, by install.sh -- see there for the verification that
# precedes it) to do an unprivileged raw-packet scan. This unit runs as
# the user, does exactly the same bounded work
# (run_bounded()/killpg/clamp()-everything, see bin/netscan-engine) as the
# interactive plugin, and the one capability involved lives on arp-scan's
# binary, not on this unit or this service -- NoNewPrivileges=yes would add
# no real security margin here, it would just silently turn the scan into
# an empty result every time the timer fires.
SERVICE_EOF
sed -i -e "s|@ENGINE@|$PLUGIN_DIR/bin/netscan-engine|" -e "s|@PYTHON@|$PYTHON_BIN|" "$SYSTEMD_USER_DIR/omarchy-netscan.service"

cat << 'TIMER_EOF' > "$SYSTEMD_USER_DIR/omarchy-netscan.timer"
[Unit]
Description=Periodic Omarchy netscan snapshot

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=false

[Install]
WantedBy=timers.target
TIMER_EOF

if command -v systemctl &>/dev/null; then
  systemctl --user daemon-reload 2>/dev/null || true
  read -r -p "[?] Enable the periodic background scan (new-device notifications, every ~15 min)? [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS])
      systemctl --user enable --now omarchy-netscan.timer && \
        echo "[*] Watch timer enabled. Manage it later with: omarchy-netscan --watch on|off|status" || \
        echo "[!] Could not enable the timer; try 'omarchy-netscan --watch on' later."
      ;;
    *)
      echo "[*] Leaving the watch timer disabled. Enable it later with: omarchy-netscan --watch on"
      ;;
  esac
else
  echo "[!] systemctl not found; skipping the periodic scan timer (systemd --user is required)."
fi

# 6. Optionally enable in shell.json (only with explicit user consent).
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