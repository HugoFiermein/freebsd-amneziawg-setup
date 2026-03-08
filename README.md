# [🇷🇺 На русском языке](README.ru.md)

# AmneziaWG FreeBSD Setup & Split Tunneling

This repository contains a professional shell script for the automated installation and configuration of **AmneziaWG** on **FreeBSD 14/15**. It handles everything from building the kernel module to setting up domain-based split tunneling.

## Key Features

* **Native Kernel Module**: Clones and compiles the AmneziaWG kernel module (`if_wg.ko`) specifically for your FreeBSD version.
* **Automated Patching**: Patches `awg-quick` on the fly to support FreeBSD-native `ifconfig` commands without requiring `amneziawg-go`.
* **Domain Split-Tunneling**: Automatically routes traffic for specific domains through the VPN while keeping the rest of your traffic on the local ISP.
* **RC Service Integration**: Creates a standard FreeBSD service (`/usr/local/etc/rc.d/amneziawg`) for easy management.
* **Clean Uninstall**: Includes a full cleanup mode (`-u`) to remove all binaries, modules, and configuration changes.

## Prerequisites

1.  **OS**: FreeBSD 14.0-RELEASE or newer (tested on FreeBSD 15-CURRENT).
2.  **Privileges**: Must be run as `root`.
3.  **Kernel Sources**: Required for building the kernel module. If missing, run:
    ```bash
    freebsd-update fetch install
    ```
4.  **AWG Config**: A valid `.conf` file from an AmneziaWG provider (containing `Jc`, `Jmin`, `Jmax` parameters).

## Usage

### Installation

Download the script and run it with your configuration:

```bash
chmod +x awg-setup.sh
sudo ./awg-setup.sh -c /path/to/vpn.conf -d "rutracker.org,nnmclub.to"
Options:-c FILE: Path to your AmneziaWG configuration file (required).-d DOMAINS: Comma-separated list of domains to tunnel. (Default: rutracker.org).-i IFACE: Name of the tunnel interface. (Default: awg0).-u: Uninstall everything.-h: Display help.Service ManagementOnce installed, use standard FreeBSD service commands:ActionCommandStart VPNservice amneziawg startStop VPNservice amneziawg stopStatusservice amneziawg statusView Statsawg show awg0TroubleshootingLogs: Installation logs are stored in /var/log/awg-setup.log.Routing: Check routing logs using grep awg-split /var/log/messages.Kernel: Ensure your kernel sources match your running system version.CreditsBuilt using high-performance kernel module forks by vgrebenschikov and tools from the amnezia-vpn project.
