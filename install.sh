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
# This modifies a system-wide binary, so it is opt-in and requires explicit
# confirmation. If skipped, the plugin will fall back to running arp-scan with
# whatever privileges are available (and README documents an alternative).
try_setcap_arpscan() {
  if ! command -v setcap &>/dev/null || ! command -v arp-scan &>/dev/null; then
    return
  fi
  ARP_SCAN_PATH=$(which arp-scan)
  if getcap "$ARP_SCAN_PATH" 2>/dev/null | grep -q "cap_net_raw"; then
    echo "[*] arp-scan already has cap_net_raw."
    return
  fi

  read -r -p "[?] Grant cap_net_raw to arp-scan for unprivileged scanning? [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS])
      echo "[*] Setting capabilities on arp-scan for unprivileged scanning..."
      sudo setcap cap_net_raw+p "$ARP_SCAN_PATH" || \
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
# We never modify the user's bar configuration without confirmation.
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
        python3 -c "
import json
with open('$SHELL_CONFIG', 'r') as f:
    data = json.load(f)
right_layout = data.setdefault('bar', {}).setdefault('layout', {}).setdefault('right', [])
if not any(item.get('id') == '$PLUGIN_ID' for item in right_layout):
    # Insert right after omarchy.network if present
    net_idx = -1
    for i, item in enumerate(right_layout):
        if item.get('id') == 'omarchy.network':
            net_idx = i
            break
    if net_idx != -1:
        right_layout.insert(net_idx + 1, {'id': '$PLUGIN_ID'})
    else:
        right_layout.append({'id': '$PLUGIN_ID'})
    with open('$SHELL_CONFIG', 'w') as f:
        json.dump(data, f, indent=2)
"
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
