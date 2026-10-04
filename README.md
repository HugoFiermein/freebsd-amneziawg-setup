**[🇷🇺 На русском языке](README.ru.md)**

# AmneziaWG FreeBSD Setup + Split Tunneling

Automated installer and configuration tool for **AmneziaWG** on **FreeBSD 13/14/15** with native kernel module performance and optional domain/subnet split tunneling.

This repository provides two specialized scripts:
* **[`awg-setup.sh`](awg-setup.sh)** — Universal installer for standard AmneziaWG 2.x protocol (`Jc`, `Jmin`, `Jmax`, `H1-H4`, `S1-S4`).
* **[`awg3-setup.sh`](awg3-setup.sh)** — Installer for the newer **AmneziaWG 3.1 (AWG3)** protocol, featuring ChaCha20 packet header encryption (`HeaderProtectionKey`), dynamic transport padding (`ContentPaddingAddition`), random trailers, and protection against AI/behavioral DPI analysis.

---

## Features

* **Native Kernel Performance**: Powered by the FreeBSD kernel driver `if_amn.ko` (from `net/amnezia-kmod`).
* **Package-Based Installation**: Automatically installs precompiled binaries via `pkg` (with ports tree fallback when needed).
* **Robust Split Tunneling**: Route specific domains and IP/CIDR subnets via `Table = off` without packet drops during CDN/Cloudflare IP rotations.
* **Full Auto-Start (rc.d)**: Automatically restores the VPN tunnel on system boot via dedicated FreeBSD services (`amneziawg` / `amneziawg3`).
* **Clean Uninstallation (`-u`)**: Safely tears down interfaces, services, and configuration without touching unrelated boot loader entries.

---

## System Requirements

1. **OS**: FreeBSD 13.0, 14.x, or 15-CURRENT.
2. **Privileges**: Must be executed as **root** (or via `sudo`).
3. **Configuration**: A valid AmneziaWG `.conf` file from your VPN provider or server.

---

## Installation & Usage

### Interactive TUI Wizard (Recommended)

Simply run the script with root privileges without arguments to launch the native FreeBSD dialog wizard:

```bash
# For AmneziaWG 3.1:
sudo ./awg3-setup.sh

# For standard AmneziaWG 2.x:
sudo ./awg-setup.sh
```

The wizard will guide you through:
1. **Language Selection**: English or Russian.
2. **Config Discovery**: Automatic scan of current directory, `$HOME`, and `/etc` for `.conf` files (or manual path entry).
3. **Routing Mode**: Full tunnel vs Split tunneling.
4. **Interactive Domain Manager**: Add or remove target domains/subnets before installation.
5. **Real-time Verification**: Post-install DNS routing and external IP verification.

---

### Non-Interactive / CLI Mode

You can also pass arguments directly for headless or automated deployments:

#### 1. AmneziaWG (Standard / 2.x)

```bash
# Full tunnel (route all internet traffic through VPN):
sudo ./awg-setup.sh -c /path/to/vpn.conf

# Split tunneling (only route specified domains and subnets through VPN):
sudo ./awg-setup.sh -c /path/to/vpn.conf -d "rutracker.org,nnmclub.to,198.51.100.0/24"
```

#### 2. AmneziaWG 3.1 (AWG3)

For configurations containing `HeaderProtectionKey`, `ContentPaddingAddition`, and `RandomTrailers`:

```bash
# Full tunnel with AWG 3.1:
sudo ./awg3-setup.sh -c /path/to/awg3.conf

# Split tunneling with AWG 3.1:
sudo ./awg3-setup.sh -c /path/to/awg3.conf -d "rutracker.org,nnmclub.to"
```

---

## Command Line Options

| Option | Description |
| :--- | :--- |
| `-c FILE` | **(Required)** Path to your AmneziaWG `.conf` file. |
| `-d TARGETS` | Optional comma-separated list of domains or IP/CIDR subnets to tunnel. *(Default: all traffic routed through VPN)*. |
| `-i IFACE` | Network interface name. *(Default: `awg0`)*. |
| `-u` | Completely uninstall service, configurations, and modules. |
| `-h` | Display usage help. |

---

## Service Management

Tunnels persist across reboots thanks to integration with FreeBSD's `rc.d` subsystem.

### Classic Service (`amneziawg`):
```bash
service amneziawg start    # Start VPN tunnel
service amneziawg stop     # Stop VPN tunnel
service amneziawg status   # Check status
awg show awg0              # View interface and peer details
```

### AWG 3.1 Service (`amneziawg3`):
```bash
service amneziawg3 start   # Start AWG 3.1 VPN tunnel
service amneziawg3 stop    # Stop AWG 3.1 VPN tunnel
service amneziawg3 status  # Check status
awg show awg0              # View interface and peer details
```

---

## Logs & Troubleshooting

* **Installation Logs**:
  * AWG: `/var/log/awg-setup.log`
  * AWG 3.1: `/var/log/awg3-setup.log`
* **Routing Activity**:
  * AWG: `grep awg-split /var/log/messages`
  * AWG 3.1: `grep awg3-split /var/log/messages`
* **Check Active Interface Routes**:
  `netstat -rn | grep awg0`
