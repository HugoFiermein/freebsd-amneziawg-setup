*[Русский](README.ru.md) | [English](README.md)*

# AmneziaWG FreeBSD Setup & Split Tunneling

A script for automated build, installation, and configuration of [AmneziaWG](https://amnezia.org/) (a WireGuard fork with DPI bypass) on **FreeBSD 14+**.

The key feature of this script is **domain-based split tunneling**. The VPN connection will only be used for the domains you specify, while all other traffic routes through your primary ISP.

The script compiles a **FreeBSD-native** AmneziaWG implementation as a kernel module (`if_wg.ko` / `if_amn`), ensuring maximum performance without relying on the slower userspace alternative (`amneziawg-go`).

## Features
* **Native Kernel Support**: Clones and builds the kernel module from the `vgrebenschikov` fork.
* **Automated Patching**: Automatically patches `awg-quick` to work natively with the FreeBSD base system (`ifconfig awg`), avoiding Linux-emulation dependencies.
* **Smart Split Tunneling**: Automatically resolves specified domains to IP addresses and dynamically adds routes into the tunnel using `PostUp` and `PostDown` hooks.
* **Daemon Management**: Generates and registers a standard `rc.d` script for service management.
* **Safe Uninstallation**: A built-in uninstaller (`-u`) safely unloads modules, cleans up startup configurations, and removes compiled binaries without touching system files.

## System Requirements
1. **OS**: FreeBSD 14.0 or newer.
2. **Privileges**: `root` (execute via `sudo`).
3. **Kernel Sources**: Required to build the kmod. If missing, install them before running:
   ```sh
   freebsd-update fetch install
AmneziaWG Config: A pre-generated configuration file (e.g., exported from the Amnezia client) containing obfuscation parameters (Jc, Jmin, Jmax, etc.).

Usage
1. Download
Download the script and make it executable:

Bash
curl -O [https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/awg-setup.sh](https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/awg-setup.sh)
chmod +x awg-setup.sh
2. Installation
Run the script, specifying the path to your config file and a comma-separated list of domains:

Bash
sudo ./awg-setup.sh -c /path/to/vpn.conf -d "rutracker.org,nnmclub.to" -i awg0
Parameters:

-c FILE — Path to the source .conf AmneziaWG file (required).

-d DOMAINS — Comma-separated list of domains to route through the VPN. Default: rutracker.org.

-i IFACE — Network interface name. Default: awg0.

-u — Complete uninstallation of AmneziaWG and all related settings.

-h — Show help.

Managing the Tunnel
Upon successful installation, the script creates a fully functional FreeBSD service.

Check status:

Bash
service amneziawg status
Start / Stop VPN:

Bash
service amneziawg start
service amneziawg stop
Check active tunnel routes:

Bash
netstat -rn | grep awg0
Check WireGuard interface statistics:

Bash
awg show awg0
Logs and Debugging
Installation log: /var/log/awg-setup.log

Split tunneling routing scripts output to the system log. To view:

Bash
grep awg-split /var/log/messages
Uninstall
To completely remove AmneziaWG, unload kernel modules, clean rc.conf, and delete binaries, run:

Bash
sudo ./awg-setup.sh -u
The script safely removes only its own components, leaving the standard WireGuard module (/boot/kernel/if_wg.ko) supplied in the FreeBSD base system untouched.

Credits
This setup relies on tools and kernel module forks provided by vgrebenschikov and the official amnezia-vpn project.
