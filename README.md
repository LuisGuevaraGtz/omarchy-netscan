# Omarchy Network Scanner 󰛳

A native, lightweight, and elegant **Network Scanner & Port Inspector plugin** for the **Omarchy Desktop Environment**.

Designed to complement the Omarchy Wi-Fi menu, this plugin lives right on your top bar as a dedicated status widget. It discovers all devices connected to your local Wi-Fi / Ethernet subnet in real-time using high-speed ARP scanning, and offers on-demand targeted Nmap port and service inspection with zero bloat.

---

## ✨ Features

- **⚡ Fast Local Network Discovery**: Discovers all active IP and MAC addresses in ~1.5 seconds using `arp-scan` (with automatic fallback to kernel neighbor tables). Devices are tracked by MAC, so they survive a DHCP-driven IP change instead of showing up as a new entry.
- **🏷️ Device Aliases**: Give any device a friendly name (`Rename` button, or the <kbd>n</kbd> shortcut) that sticks around across rescans, reinstalls, and IP changes.
- **🎯 Targeted On-Demand Port Scanning**: Adheres strictly to a privacy-first, low-noise philosophy. Nmap port and service inspection is **never** run across the entire network—only on explicit user demand for a selected host.
- **🔬 Deep Scan**: An explicit, opt-in ~30s Nmap inspection (service versions, banners, and HTTP/TLS/UPnP identity) for when the fast scan and vendor OUI alone aren't enough to tell you what a device is.
- **🔔 Optional Periodic Watch**: A `systemd --user` timer (off by default) that snapshots the network every ~15 minutes and notifies you about newly seen devices — nothing stays resident between runs.
- **🎨 100% Native Omarchy Aesthetic**: Built directly with Quickshell and Omarchy's design system (`qs.Commons`, `qs.Ui`, `BorderSurface`). Features dark background styling, subtle accents, monospace typography, and clean negative space.
- **🔍 Smart Device Categorization**: Automatically identifies and badges Gateways (`[GW]`), Local Host (`[YOU]`), Mobile devices, Computers, and Smart IoT devices based on OUI vendor signatures.
- **⌨️ Complete Keyboard & Mouse Control**: Full navigation support via <kbd>j</kbd> / <kbd>k</kbd>, <kbd>↑</kbd> / <kbd>↓</kbd>, <kbd>s</kbd> (Scan), <kbd>S</kbd> (Deep Scan), <kbd>n</kbd> (Rename), <kbd>c</kbd> (Copy), <kbd>r</kbd> (Refresh), and <kbd>Esc</kbd>.
- **📋 Instant Utilities**: 1-click IP copy to clipboard (`wl-copy`) and instant browser launch for web services (HTTP 80/8080/443).
- **🚀 CLI Companion Included**: Includes the `omarchy-netscan` terminal utility to toggle the UI or run text scans directly in your shell.

---

## 📸 Preview

The Network Scanner widget lives right on your Omarchy top bar and opens a native, dark-themed popup:

![Network Scanner plugin popup](screenshots/omarchy-netscan-plugin-only.png)

*For a full desktop context:*

![Network Scanner on the full desktop](screenshots/omarchy-netscan-full-screen.png)

---

## 📦 Requirements

The plugin relies on standard, unprivileged network utilities:

- **`python3`** — required: the scanning engine is a Python 3 script.
- **`arp-scan`** — recommended: fast raw-packet discovery with vendor OUI.
  Without it the panel falls back to the kernel neighbor table (fewer
  devices, no vendor names).
- **`nmap`** — required only for the per-host port / deep scans; without it
  those buttons report "nmap binary not found" instead of scanning.
- **`wl-copy`** — for the Copy-IP button (Wayland clipboard).
- **`notify-send`** — only used by the optional periodic watch timer.

Install them with your system package manager, e.g.:

```bash
sudo pacman -S arp-scan nmap python      # Arch / Omarchy
sudo apt install arp-scan nmap python3   # Debian / Ubuntu
sudo dnf install arp-scan nmap python3   # Fedora
```

> **Note**: To allow `arp-scan` to perform raw socket scanning without prompting for `sudo`, you may grant it the `cap_net_raw` capability (optional):
> ```bash
> sudo setcap cap_net_raw+p $(which arp-scan)
> ```
> `install.sh` will ask for your explicit confirmation before modifying this system-wide binary. If you decline, the plugin still works — `arp-scan` will simply run with standard privileges (you may need to run it under `sudo` instead).
>
> Before touching the binary, the installer verifies it is the real, unmodified
> `/usr/bin/arp-scan` — canonical path (no `$PATH`-shadowing), root-owned,
> not group/other-writable, and confirmed by `pacman` to both belong to the
> `arp-scan` package and pass its file-integrity check. Any failure aborts
> the step; it never falls back to trusting a bare `which arp-scan` hit. On
> distros without `pacman` the provenance check can't run, so the `setcap`
> step is skipped entirely rather than weakened — the plugin still works
> without it.

---

## 🛠️ Installation

### Method 1: Using Omarchy CLI (Recommended)

```bash
omarchy plugin add https://github.com/LuisGuevaraGtz/omarchy-netscan.git
```

### Method 2: Manual Installation

1. Clone this repository into your Omarchy plugins folder (`$XDG_CONFIG_HOME`
   is honored by both `install.sh` and `uninstall.sh`; the default is
   `~/.config`):
```bash
git clone https://github.com/LuisGuevaraGtz/omarchy-netscan.git "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/lu15ggtz.netscan"
```

2. Run the automated setup script:
```bash
cd "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/lu15ggtz.netscan"
./install.sh
```

3. Ensure the plugin widget is added to your bar layout in `~/.config/omarchy/shell.json`:
```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "omarchy.network" },
        { "id": "lu15ggtz.netscan" },
        { "id": "omarchy.audio" }
      ]
    }
  }
}
```

The installer will ask for your explicit confirmation before adding the widget
to `~/.config/omarchy/shell.json`. If you decline, the plugin is installed but
not shown on your bar; enable it later with:

```bash
omarchy plugin enable lu15ggtz.netscan
```

Once enabled, Omarchy's shell detects the plugin and renders the `󰛳` icon on your top bar.

> **Portability**: nothing that runs the plugin is distro-specific. `install.sh`
> only hard-requires `python3`; missing `arp-scan`/`nmap` produce a warning (not
> an abort) and the engine degrades gracefully. The CLI wrapper and the
> systemd watch-timer unit are generated from the resolved plugin path, so a
> non-standard `$XDG_CONFIG_HOME` keeps working.

---

## ⚙️ Settings

The widget reads per-instance settings from its `shell.json` bar entry
(`panelWidth`), tunable from Omarchy's widget settings:

| Key | Type | Default | Range | Description |
| :--- | :--- | :--- | :--- | :--- |
| `panelWidth` | integer | 430 | 320–720 | Width of the scanner popup, in px. |

The value is clamped in QML between 320 and 720, so a hand-edited value can't
produce a degenerate panel.

---

## 🧪 Testing

The engine ships an offline unit-test suite (fictional data only — no
`arp-scan`, `nmap`, or network access required):

```bash
python3 -m unittest discover -s tests -v
```

This covers MAC/alias sanitization, device classification, bounded subprocess
handling (timeout + output truncation), `arp-scan`/neighbor-table parsing,
fast/deep nmap result parsing, DNS/mDNS hostname resolution, and the snapshot
new-device diff (first run, no-change, new device, stale-device pruning).
A GitHub Actions workflow runs the same suite on every push/PR.

---

## 🏷️ Device Aliases

Select a device and press <kbd>n</kbd> (or click **Rename**) to give it a
friendly name — "Repetidor sala", "Camara garage", whatever's useful.
Aliases are stored at `$XDG_CONFIG_HOME/omarchy-netscan/aliases.json`
(`~/.config/omarchy-netscan/aliases.json` by default), keyed by MAC address
— **not** inside the plugin directory, so reinstalling the plugin never
wipes the names you've typed in. Clearing the name field removes the alias.

You can also manage aliases from the terminal:

```bash
omarchy-netscan --cli               # aliases show up as the "alias" field per device
python3 ~/.config/omarchy/plugins/lu15ggtz.netscan/bin/netscan-engine alias list
python3 ~/.config/omarchy/plugins/lu15ggtz.netscan/bin/netscan-engine alias set <mac> "My Device"
python3 ~/.config/omarchy/plugins/lu15ggtz.netscan/bin/netscan-engine alias rm <mac>
```

> **Note on `Locally Administered` devices**: iOS and Android generate a
> random "private" MAC address per Wi-Fi network by default, which is what
> shows up here as `Locally Administered`/`Unknown Vendor`. That random MAC
> is normally *stable for as long as the phone stays on the same SSID*, so
> an alias you set for one usually keeps working — but if the device
> rotates its MAC (some devices do this periodically, or on
> forget-and-rejoin), the alias becomes orphaned under the old MAC and the
> device reappears as a new, unnamed entry. The `lastSeen` timestamp kept
> in the periodic-scan snapshot (see below) is the easiest way to spot
> those dead entries later.

---

## 🔬 Deep Scan

The regular <kbd>s</kbd> port scan is intentionally fast and shallow. When
that (plus the OUI vendor guess) isn't enough to identify a device, select
it and press <kbd>S</kbd> (Shift+S) or click **Deep** for a slower,
explicit Nmap inspection:

- Service **versions** for each open port (not just port + name).
- A handful of NSE scripts (`banner`, `http-title`, `ssl-cert`,
  `upnp-info`) that surface a **page title**, a **TLS certificate common
  name**, and/or a **UPnP model/manufacturer string** — usually enough to
  turn "Unknown Vendor at .124" into "that's the printer."

This can take **up to ~30 seconds** (the UI says so up front) since it's a
full version/script scan rather than a quick port sweep — that's why it's
never run automatically. Results are cached per-device for the session, so
revisiting a device you've already deep-scanned shows the cached result
(with its age) instantly instead of re-running Nmap.

It does **not** use `-O` or `-sS`: both require root, and this plugin never
asks for elevated privileges beyond the optional `cap_net_raw` grant to
`arp-scan` described above.

---

## 🔔 Periodic Watch Timer (optional)

A `systemd --user` timer, off by default, that runs the same bounded
discovery as the panel — `netscan-engine snapshot` — every ~15 minutes and
sends a desktop notification when it sees a device it hasn't seen before on
the current network. It keeps a small history at
`$XDG_STATE_HOME/omarchy-netscan/` (`~/.local/state/omarchy-netscan/` by
default), one snapshot file per network (keyed by the gateway's MAC, so
moving between Wi-Fi networks — home, a coffee shop, work — doesn't cause a
flood of false "new device" alerts). Devices not seen in 30 days are pruned
automatically.

It's **opt-in** — `install.sh` asks before enabling it, same as the
`cap_net_raw` and bar-widget prompts — and it leaves **nothing running
between runs**: it's a `Type=oneshot` service woken up by a timer, not a
daemon.

```bash
omarchy-netscan --watch on       # enable the timer
omarchy-netscan --watch off      # disable it
omarchy-netscan --watch status   # check whether it's enabled/active
```

You can also manage it directly with `systemctl --user
[enable|disable|status] omarchy-netscan.timer`.

---

## 🗑️ Uninstall

To fully remove the plugin (plugin files, CLI wrapper, bar widget entry, and
the watch timer):

```bash
./uninstall.sh
```

This reverses everything the installer created. It does **not** remove the
system packages (`arp-scan`, `nmap`, `python`), and it will only revoke
`cap_net_raw` from `arp-scan` if you explicitly confirm — since that capability
may be shared with other tools. It also asks **separately** whether to delete
your aliases and snapshot history (`~/.config/omarchy-netscan/`,
`~/.local/state/omarchy-netscan/`) — default is to keep them, since that's
where the names you've typed in live.

> **Tip**: You can also simply delete the folder. To remove from the bar without
> uninstalling the plugin, remove the `{ "id": "lu15ggtz.netscan" }` entry from
> `~/.config/omarchy/shell.json` or run `omarchy plugin disable lu15ggtz.netscan`.

---

## 🔒 Security notes

- **Bounded scanning.** `ip`, `arp-scan`, and `nmap` are run in their own
  process group with their stdout capped at a fixed size instead of buffered
  without limit. If a host on the network floods a scan with an oversized
  reply (or a scan simply hangs), the whole process group is killed
  immediately on overflow or timeout — nothing is left running or growing
  unbounded in memory.
- **Bounded output.** Every string pulled from scan output (vendor name,
  service, version, …), the number of devices/ports returned, and the final
  JSON payload itself are all length-capped, so a malicious device can't use
  a crafted response to blow up memory or the panel UI.
- **`shell.json` writes are safe.** Both `install.sh` and `uninstall.sh` open
  `~/.config/omarchy/shell.json` with `O_NOFOLLOW` (refusing to follow a
  symlink planted at that path) and write changes atomically via a
  same-directory temp file + `rename()`, never truncating the file in place.
- **`setcap` is tightly bound**, as described above — canonical path, root
  ownership, safe permissions, and `pacman` package/integrity verification,
  every time, before any privileged write.
- **Aliases and snapshots are safe to read/write.** `aliases.json` and the
  periodic snapshot files live under `$XDG_CONFIG_HOME`/`$XDG_STATE_HOME`
  (dir mode `0700`, file mode `0600`), are read with `O_NOFOLLOW`, and are
  written atomically the same way `shell.json` is. Every entry is bounded
  (alias length, device count, config/snapshot file size); a corrupted or
  hand-edited file is treated as empty rather than trusted or crashed on.
- **The gateway MAC used to key a snapshot file is never trusted as a path.**
  It's re-validated as a MAC and, either way, only ever reaches the
  filesystem as a SHA-256 hash (`snapshot-<16 hex>.json`) — a spoofed
  gateway reply on the LAN can't be used to make the snapshot writer touch
  a path outside its state directory.
- **Deep-scan and notification strings are bounded too.** Every field pulled
  from an Nmap script (banner, HTTP title, TLS certificate CN, UPnP model)
  is individually length-capped, and a new-device desktop notification's
  vendor/IP text is clamped, control-character-stripped, and passed to
  `notify-send` after a bare `--` so a vendor string starting with `-`
  can't be read as a flag.
- **The watch timer doesn't need `NoNewPrivileges=yes`, and deliberately
  doesn't set it** — see the comment in `systemd/omarchy-netscan.service`.
  It would block `arp-scan`'s `cap_net_raw` file capability from taking
  effect and silently turn every scheduled scan into an empty result; the
  unit does the same bounded, unprivileged work as the interactive plugin.

---

## ⌨️ Shortcuts & Navigation

| Key | Action |
| :--- | :--- |
| <kbd>j</kbd> / <kbd>↓</kbd> | Move to the next discovered device |
| <kbd>k</kbd> / <kbd>↑</kbd> | Move to the previous discovered device |
| <kbd>s</kbd> or <kbd>p</kbd> | Trigger **fast Nmap port scan** on the selected host |
| <kbd>S</kbd> (Shift+S) | Trigger **Deep Scan** (service versions + identity, ~30s) |
| <kbd>n</kbd> | **Rename** the selected device (set/clear its alias) |
| <kbd>c</kbd> | **Copy IP address** to clipboard |
| <kbd>r</kbd> | **Refresh / Rescan** network via ARP |
| <kbd>Esc</kbd> | Close the scanner popup (or cancel a rename in progress) |

### Hyprland Global Keybinding (Optional)

To bind a global shortcut (e.g. <kbd>SUPER</kbd> + <kbd>N</kbd>) to toggle the scanner popup from anywhere, add this to `~/.config/hypr/bindings.lua`:

```lua
-- Toggle Network Scanner Popup
o.bind("SUPER + N", "Network Scanner", "omarchy-netscan")
```

---

## 🖥️ CLI Usage

You can also interact with the scanner directly from any terminal:

```bash
# Toggle the floating UI popup on the bar
omarchy-netscan

# Output discovered hosts in JSON format
omarchy-netscan --cli

# Scan open ports on a specific IP in terminal
omarchy-netscan --ports 192.168.100.1

# Manage the optional periodic watch timer
omarchy-netscan --watch on
omarchy-netscan --watch off
omarchy-netscan --watch status
```

---

## 🚀 Publishing to omarchyplugins.com

This repository contains a valid `manifest.json` adhering to `schemaVersion: 1`,
a root README with install/remove instructions, and a root MIT license. To
submit and publish this plugin to the community directory at
[omarchyplugins.com](https://omarchyplugins.com):

1. Push your repository to GitHub: `https://github.com/LuisGuevaraGtz/omarchy-netscan`.
2. Open a submission issue on the Omarchy plugin marketplace repository
   (`HANCORE-linux/omarchy-plugin-marketplace`) with the title
   `[Plugin]: Network Scanner`.
3. The automated pipeline validates the manifest, checks the entry points, and
   runs a static exact-commit security baseline against the repository before a
   maintainer's `approved-and-verified` decision.
4. Suggested listing values: category **System**, tags **bar**, **quickshell**,
   **security**.

Any later push creates a new commit that is no longer covered by the verified
snapshot until a full-SHA update request is approved — so bump the manifest
`version` and retest locally (see [Testing](#-testing)) before tagging a
release.

---

## 📄 License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for more information.

Author: **Luis Adolfo Guevara Gutierrez** ([@LuisGuevaraGtz](https://github.com/LuisGuevaraGtz))
