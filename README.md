[🇷🇺 На русском языке](README.ru.md)

# AmneziaWG FreeBSD Setup & Split Tunneling

This repository provides an automated solution for installing and configuring **AmneziaWG** on **FreeBSD 14/15**. It builds the kernel module from source and enables high-performance VPN connectivity with optional domain-based routing.

---

## Features

* **Native Kernel Performance**: Clones and compiles the AmneziaWG kernel module (`if_wg.ko`) for your specific FreeBSD version.
* **Intelligent Patching**: Modifies `awg-quick` to work natively with FreeBSD's `ifconfig`, removing the need for `amneziawg-go`.
* **Optional Split Tunneling**: Route traffic for specific domains through the VPN while keeping everything else on your local ISP.
* **Full Auto-Start**: Registers a standard FreeBSD service (`/usr/local/etc/rc.d/amneziawg`) that starts automatically upon reboot.
* **Clean Uninstallation**: Includes a dedicated uninstall flag (`-u`) to safely remove all binaries and modules.

---

## Prerequisites

1. **OS**: FreeBSD 14.0-RELEASE or newer (supports FreeBSD 15-CURRENT).
2. **Privileges**: Must be executed as **root** (or via `sudo`).
3. **Kernel Sources**: Required to compile the module. Install via:
   `freebsd-update fetch install`
4. **Configuration**: A valid `.conf` file from an AmneziaWG provider is required.

---

## Installation & Usage

### 1. Basic Installation
To install AmneziaWG with default settings, simply provide your configuration file:
`sudo ./awg-setup.sh -c /path/to/vpn.conf`

### 2. Advanced Usage (Split Tunneling)
If you want the VPN to handle only specific domains, use the `-d` option:
`sudo ./awg-setup.sh -c /path/to/vpn.conf -d "rutracker.org,nnmclub.to"`

### All Options
* `-c FILE`: **(Required)** Path to your AmneziaWG `.conf` file.
* `-d DOMAINS`: Optional comma-separated list of domains to tunnel. (Default: `rutracker.org`).
* `-i IFACE`: Name of the tunnel interface. (Default: `awg0`).
* `-u`: Uninstall and clean the system.

---

## Service Management

The tunnel stays active after reboots thanks to the integrated RC service.

| Action | Command |
| :--- | :--- |
| **Start VPN** | service amneziawg start |
| **Stop VPN** | service amneziawg stop |
| **Status** | service amneziawg status |
| **Interface Info** | awg show awg0 |

---

## Troubleshooting & Logs

* **Installation Logs**: Found at `/var/log/awg-setup.log`.
* **Routing Activity**: View split tunneling events:
  `grep awg-split /var/log/messages`
* **Kernel Mismatch**: Ensure `/usr/src` matches your kernel version (`uname -r`).

---

## Credits
Utilizes kernel module forks and tools by [vgrebenschikov](https://github.com/vgrebenschikov) and [amnezia-vpn](https://github.com/amnezia-vpn).
