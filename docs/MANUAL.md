# AmneziaWG FreeBSD — Visual Setup Guide & Manual

**[🇷🇺 Руководство на русском языке](MANUAL.ru.md)** | **[⬅ Back to Main README](../README.md)**

---

This step-by-step visual guide walks through configuring **AmneziaWG** on FreeBSD using the built-in interactive **TUI Wizard** (`bsddialog`).

The wizard is available in both scripts:
* **[`awg2-setup.sh`](../awg2-setup.sh)** — for AmneziaWG 2.0 / 1.0 protocols
* **[`awg3-setup.sh`](../awg3-setup.sh)** — for AmneziaWG 3.1 protocols (ChaCha20 Header Protection & dynamic padding)

---

## Launching the Wizard

Run the script without arguments with root privileges:

```bash
# For AmneziaWG 3.1:
sudo ./awg3-setup.sh

# Or for AmneziaWG 2.0 / 1.0:
sudo ./awg2-setup.sh
```

---

## Step 1: Interface Language Selection

When launched, the installer presents a language selection menu. Choose your preferred language:
* **`English (Default)`** — Full English interface and logging
* **`Русский`** — Russian interface and localization

![Step 1: Language Selection](screenshots/step1-language.png)

Navigate using `Up`/`Down` arrow keys, press `Enter` or select `[ OK ]`.

---

## Step 2: Configuration File Discovery & Selection

The wizard automatically scans standard paths for AmneziaWG `.conf` configuration files:
* Current working directory (`./*.conf`)
* User home directories (`/home/*/*.conf`, `/root/*.conf`)
* System configuration directories (`/etc/*.conf`, `/usr/local/etc/*.conf`)

![Step 2: Configuration File Selection](screenshots/step2-config-selection.png)

* **Select a detected file**: Press the corresponding number (e.g., `1`, `2`) and select `[ OK ]`.
* **Enter path manually**: Choose `C Enter path manually...` to provide an exact path to a configuration file located elsewhere.

---

## Step 3: Traffic Routing Mode

Choose how traffic should be routed through the VPN tunnel:

![Step 3: Routing Mode Selection](screenshots/step3-routing-mode.png)

1. **`Full Tunnel - Route ALL internet traffic via VPN`**:
   * All network traffic from this FreeBSD host will be encapsulated and sent through the AmneziaWG tunnel.
   * Equivalent to `AllowedIPs = 0.0.0.0/0, ::/0` with default gateway override.

2. **`Split Tunneling - Route only selected domains / IPs`**:
   * Only traffic directed to specified domains or IP subnets is routed through the VPN.
   * All regular internet traffic continues via the host's direct ISP/gateway connection.
   * Utilizes FreeBSD native static routing with automatic Anycast round-robin DNS resolution.

---

## Step 4: Split Tunneling Target Manager

*(Appears only if "Split Tunneling" was selected in Step 3)*

The target manager allows you to inspect, add, and remove domains or IP/CIDR subnets before applying changes:

![Step 4: Split Tunneling Manager](screenshots/step4-split-tunnel-manager.png)

### Actions:
* **`ADD [+] Add domain or IP/CIDR`**: Opens an input prompt where you can enter one or multiple targets (comma or space separated, e.g. `rutracker.org, google.com, microsoft.com, 198.51.100.0/24`).
* **`DEL [-] Remove last added item`**: Removes the most recently added target from the list.
* **`CLEAR [X] Clear all items`**: Clears all targets to start fresh.
* **`DONE [OK] Proceed with this list`**: Confirms the target list and advances to the summary screen.

---

## Step 5: Installation Summary & Confirmation

Before any system modifications, kernel builds, or network interface changes occur, a summary dialog displays the selected configuration:

![Step 5: Pre-Installation Summary](screenshots/step5-summary.png)

* **Config file**: Absolute path to the validated `.conf` file.
* **Interface**: Interface name (`awg0` by default).
* **Routing Mode**: `Full Tunnel` or `Split Tunneling` (with list of target destinations).

Select **`[ Yes ]`** to proceed with automated module setup, driver compilation/loading, and service activation. Select **`[ No ]`** to safely abort without changing system state.

---

## Step 6: Setup Complete & Live Verification

Once installation and initialization finish, the wizard displays the final verification dialog:

![Step 6: Setup Complete](screenshots/step6-complete.png)

### Verified Metrics:
* **Protocol**: Protocol version and driver details (e.g., `AmneziaWG 3.1 (ChaCha20 Header Protection)`).
* **Interface**: Active network interface name (`awg0`).
* **Mode**: Active routing mode and destination targets.
* **External IP**: Verified public IP address seen through the tunnel.
* **Handshake**: Real-time handshake latency (e.g., `Active (3 sec ago)`).

---

## Managing the Service

After completing setup, the VPN interface and routes automatically persist across reboots via FreeBSD `rc.d`.

### AWG 3.1 (`awg3-setup.sh`):
```bash
sudo service amneziawg3 status   # Check tunnel status and active handshake
sudo service amneziawg3 stop     # Stop tunnel and tear down routes
sudo service amneziawg3 start    # Start tunnel and re-apply routes
sudo awg show awg0               # Detailed wire protocol metrics & key stats
```

### AWG 2.0 / 1.0 (`awg2-setup.sh`):
```bash
sudo service amneziawg status    # Check tunnel status
sudo service amneziawg stop      # Stop tunnel
sudo service amneziawg start     # Start tunnel
sudo awg show awg0               # Detailed peer & transfer metrics
```

### Verifying Split Routes:
```bash
# Check all routes assigned to the awg0 interface:
netstat -rn | grep awg0

# Test routing for a specific destination domain:
route get rutracker.org
route get google.com

# Verify end-to-end HTTPS connectivity:
curl -4 -I https://rutracker.org
```

---

## Headless / Non-Interactive Usage

To bypass the TUI wizard for automated deployments or scripts, use CLI arguments directly:

```bash
# AmneziaWG 3.1 Full Tunnel:
sudo ./awg3-setup.sh -c /path/to/vpn.conf

# AmneziaWG 3.1 Split Tunneling:
sudo ./awg3-setup.sh -c /path/to/vpn.conf -d "rutracker.org,google.com,microsoft.com"

# AmneziaWG 2.0 / 1.0 Split Tunneling:
sudo ./awg2-setup.sh -c /path/to/vpn.conf -d "rutracker.org,google.com,microsoft.com"
```
