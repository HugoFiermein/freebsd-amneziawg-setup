# [🇷🇺 На русском языке](README.ru.md)

# AmneziaWG FreeBSD Setup & Split Tunneling

This repository provides an automated solution for installing and configuring **AmneziaWG** on **FreeBSD 14/15**. It is designed to build the kernel module from source and set up efficient, domain-based split tunneling.

---

## Features

* **Native Kernel Performance**: Clones and compiles the AmneziaWG kernel module (`if_wg.ko`) tailored for your specific FreeBSD version.
* **Intelligent Patching**: Automatically modifies `awg-quick` to work natively with FreeBSD's `ifconfig`, removing the need for `amneziawg-go`.
* **Domain-Based Split Tunneling**: Automatically routes traffic for specific domains through the VPN tunnel while keeping all other traffic on your local ISP.
* **Service Integration**: Registers a standard FreeBSD service (`/usr/local/etc/rc.d/amneziawg`) for persistent startup and easy management.
* **Clean Uninstallation**: Includes a dedicated uninstall flag (`-u`) to safely remove all binaries, kernel modules, and configuration changes.

---

## Prerequisites

1. **OS**: FreeBSD 14.0-RELEASE or newer (fully supports FreeBSD 15-CURRENT).
2. **Privileges**: The script must be executed as **root** (or via `sudo`).
3. **Kernel Sources**: Required to compile the kernel module. If they are missing, install them with:
   `freebsd-update fetch install`
4. **Configuration**: You need a valid `.conf` file from an AmneziaWG provider (containing `Jc`, `Jmin`, `Jmax` parameters).

---

## Installation & Usage

### 1. Download and Prepare
`chmod +x awg-setup.sh`

### 2. Run the Setup
Run the script by providing the path to your configuration file and the list of domains you wish to tunnel:
`sudo ./awg-setup.sh -c /path/to/vpn.conf -d "rutracker.org,nnmclub.to"`

### Options
* `-c FILE`: **(Required)** Path to your AmneziaWG `.conf` file.
* `-d DOMAINS`: Comma-separated list of domains to tunnel. (Default: `rutracker.org`).
* `-i IFACE`: Name of the tunnel interface. (Default: `awg0`).
* `-u`: Uninstall and clean the system.
* `-h`: Display help and usage examples.

---

## Service Management

The script installs a native RC service. Use the following commands to manage your VPN:

| Action | Command |
| :--- | :--- |
| **Start VPN** | service amneziawg start |
| **Stop VPN** | service amneziawg stop |
| **Status** | service amneziawg status |
| **Interface Info** | awg show awg0 |
| **Routing Table** | netstat -rn | grep awg0 |

---

## Troubleshooting & Logs

* **Installation Logs**: Detailed logs are stored at `/var/log/awg-setup.log`.
* **Routing Activity**: Split tunneling events and resolution errors are logged to the system log. View them with:
  `grep awg-split /var/log/messages`
* **Kernel Mismatch**: If the kernel module fails to load, ensure your `/usr/src` matches your running kernel version (`uname -r`).

---

## Credits
This script utilizes high-performance kernel module forks and tools maintained by [vgrebenschikov](https://github.com/vgrebenschikov) and the [amnezia-vpn](https://github.com/amnezia-vpn) project.
