# Raspberry Pi 4 Headless OpenWrt NAS Appliance

A production-grade, self-healing, headless Network Attached Storage (NAS) firmware appliance built on **OpenWrt 25.12** for the **Raspberry Pi 4 Model B**. 

Designed from the ground up for reliable 100% remote operation without physical access, featuring authenticated WebDAV file sharing, zero-touch Tailscale mesh networking, automatic multi-SSID WiFi failover, dynamic DNS, automated Let's Encrypt TLS certificates, and a hardware-resilient remote upgrade engine with autonomous stock rollback and diagnostic telemetry.

---

## Key Features

- **High-Performance WebDAV Storage**:
  - Serves external USB storage over HTTP (`:8080`) and HTTPS (`:8443`), avoiding conflicts with the OpenWrt LuCI web admin interface on ports `80` and `443`.
  - PAM authentication allows system user login (`$NAS_USER`).
  - Strict unmounted storage protection: locks mountpoints to `root:root 0700` when no drive is connected, rejecting writes with `500 Permission Denied` to prevent RAM exhaustion.
  - Multi-user collaboration: WebDAV daemon runs as `www-data` (`umask 0002`), ensuring files created by WebDAV or direct SSH/local users share group permissions (`$NAS_USER:www-data 0775 / 0664`).
  - Supports `ext4`, `btrfs`, `f2fs`, `NTFS`, `exFAT`, and `FAT32` with automatic hotplug detection and mounting.

- **Zero-Touch Mesh Networking (Tailscale)**:
  - Embeds Tailscale daemon and zero-touch auto-join service.
  - Automatically joins your Tailscale tailnet on first boot using a one-time pre-authenticated auth key.
  - Preserves persistent node state across reboots and upgrades.

- **Automated Multi-Network WiFi Failover**:
  - Dynamic dual-interface configuration: Ethernet (`eth0`, metric 10, primary) and WiFi (`wlan0`, metric 20, fallback).
  - Background failover daemon (`nas-wifi-failover`) monitors physical Ethernet link carrier.
  - When Ethernet is connected, WiFi stays in low-power standby (`disabled '1'`).
  - When Ethernet is unplugged or unavailable, the daemon automatically scans 2.4 GHz and 5 GHz bands and connects to Priority 1 (`WIFI_SSID_1`) or Priority 2 (`WIFI_SSID_2`) networks with WPA2/WPA3 support, seamlessly switching routes.

- **Automated Dynamic DNS & TLS Certificates**:
  - Cloudflare Dynamic DNS updates public IPv4 records upon WAN changes.
  - ACME client issues and renews official Let's Encrypt certificates via Cloudflare DNS-01 challenges without requiring open inbound router ports.
  - Automatically reloads the WebDAV SSL certificate upon renewal.

- **Hardware-Resilient Remote Upgrades & Autonomous Rollback**:
  - Direct hardware root device mapping (`root=/dev/mmcblk0p2`) eliminates fragile MBR `PARTUUID` mismatch kernel panics.
  - Dedicated persistent recovery partition (`/recovery` on `/dev/mmcblk0p3`) stores pristine stock golden firmware, checksums, and initial config.
  - Watchdog verification trial (`nas-recovery`): monitors OpenSSH, Tailscale, and WebDAV after an upgrade reboot.
  - If core services fail to stabilize within 45 seconds, the system automatically collects comprehensive diagnostics into persistent storage, flashes the baseline stock firmware, and reboots.
  - Client upgrade script (`scripts/remote_upgrade.sh`) automatically retrieves the failure bundle, extracts logs, and presents an itemized diagnostic breakdown for troubleshooting.

---

## Hardware Requirements

- **Board**: Raspberry Pi 4 Model B (1 GB, 2 GB, 4 GB, or 8 GB RAM).
- **Storage**:
  - MicroSD Card: 1 GB or larger (Class 10 / A1 / A2 recommended).
  - External USB Drive: USB 3.0 HDD, SSD, or flash drive (formatted as `ext4`, `NTFS`, `exFAT`, etc.).
- **Connectivity**:
  - Gigabit Ethernet cable (recommended for primary connection).
  - 2.4 GHz or 5 GHz WiFi network (optional, for failover).

---

## Quick Start Guide

### Step 1: Clone Repository
```bash
git clone https://github.com/your-username/rpi-nas-openwrt.git
cd rpi-nas-openwrt
```

### Step 2: Configure Environment Variables
Copy the template configuration file:
```bash
cp .env.example .env
```
Edit `.env` using your favorite text editor (e.g. `nano .env`) to set your credentials and configuration:
```bash
DEVICE_HOSTNAME=rpi4nas
NAS_USER=myuser
NAS_PASSWORD=ChooseAStrongPassword
ROOT_PASSWORD=ChooseAStrongPassword
SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub
```

### Step 3: Compile Firmware Images
Build the factory and sysupgrade images using Docker:
```bash
./build.sh
```
The build process compiles OpenWrt and exports the output to the `output/` directory:
- `output/openwrt-25.12.5-bcm27xx-bcm2711-rpi-4-squashfs-factory.img`: Ready for initial microSD card flashing.
- `output/openwrt-25.12.5-bcm27xx-bcm2711-rpi-4-squashfs-sysupgrade.img.gz`: Used for future over-the-network remote upgrades.

### Step 4: Flash MicroSD Card
Insert your microSD card into your computer, identify its device node (e.g., `/dev/sdb` or `/dev/mmcblk0`), and execute the safe flashing script:
```bash
./scripts/flash_sd.sh /dev/sdX
```
*(The script verifies that target devices are not part of your host OS before writing).*

### Step 5: Boot the Appliance
1. Insert the flashed microSD card into the Raspberry Pi 4.
2. Connect your external USB hard drive or SSD to one of the blue USB 3.0 ports.
3. Plug in the Ethernet cable (or ensure configured WiFi networks are in range).
4. Connect the USB-C power supply.

Within 60–90 seconds, the Raspberry Pi will boot, initialize the recovery storage, mount the USB drive, connect to Tailscale, and start all services.

---

## Configuration Reference (`.env`)

| Variable | Required | Default | Description |
| :--- | :---: | :--- | :--- |
| `OPENWRT_VERSION` | Yes | `25.12.5` | OpenWrt release version. |
| `OPENWRT_TARGET` | Yes | `bcm27xx/bcm2711` | OpenWrt target architecture. |
| `OPENWRT_PROFILE` | Yes | `rpi-4` | Target hardware profile. |
| `DEVICE_HOSTNAME` | Yes | `rpi4nas` | System hostname and local network identity. |
| `NAS_USER` | Yes | `nasuser` | Standard non-root user with sudo and WebDAV access. |
| `NAS_PASSWORD` | Yes | - | Password for `$NAS_USER` (SSH, sudo, WebDAV). |
| `ROOT_PASSWORD` | No | `$NAS_PASSWORD` | Root password for console / SSH. |
| `SSH_PUBLIC_KEY` | Yes | - | Path to local public key (e.g. `~/.ssh/id_ed25519.pub`) or key string. |
| `TAILSCALE_AUTH_KEY` | No | Empty | Pre-authenticated reusable auth key for zero-touch VPN join. |
| `DDNS_DOMAIN` | No | Empty | FQDN for Dynamic DNS (e.g., `nas.example.com`). |
| `DDNS_TOKEN` | Cond. | Empty | Cloudflare API Token with `Zone.DNS:Edit` permissions. |
| `ACME_DOMAIN` | No | Empty | Domain to request Let's Encrypt certificate for. |
| `ACME_EMAIL` | Cond. | Empty | Email address for Let's Encrypt expiry notices. |
| `ACME_CREDENTIALS`| Cond. | Empty | DNS API credentials (e.g., `CF_Token="your_token"`). |
| `ACME_STAGING` | No | `0` | Set `1` to test against Let's Encrypt Staging environment. |
| `WIFI_SSID_1` | No | Empty | Primary fallback WiFi SSID. |
| `WIFI_PASSWORD_1`| No | Empty | Primary fallback WiFi password (supports WPA2/WPA3). |
| `WIFI_SSID_2` | No | Empty | Secondary fallback WiFi SSID. |
| `WIFI_PASSWORD_2`| No | Empty | Secondary fallback WiFi password. |

---

## Accessing Your NAS

### 1. SSH & SFTP Management
Connect using OpenSSH on port `22` using your SSH key or password:
```bash
# As non-root user
ssh myuser@rpi4nas

# As root administrator
ssh root@rpi4nas
```
*Note: OpenSSH is configured with `StrictModes no` and key authentication enabled for both accounts.*

### 2. WebDAV File Sharing
Connect using any WebDAV-compatible file manager or mobile app:
- **HTTP**: `http://<ip-or-tailscale-name>:8080/`
- **HTTPS**: `https://<ip-or-tailscale-name>:8443/`

#### Client Configuration Examples:
- **Windows (File Explorer)**:
  1. Open *This PC* -> *Add a network location* (or *Map network drive*).
  2. Enter: `http://rpi4nas:8080/` or `https://rpi4nas:8443/`
  3. When prompted, enter your `$NAS_USER` and `$NAS_PASSWORD`.
- **macOS (Finder)**:
  1. In Finder, press `Cmd + K` (*Connect to Server*).
  2. Enter: `http://rpi4nas:8080/` or `https://rpi4nas:8443/`
  3. Authenticate with Registered User credentials (`$NAS_USER` / `$NAS_PASSWORD`).
- **Linux (GNOME Files / Dolphin / CLI)**:
  - Enter `dav://rpi4nas:8080/` or `davs://rpi4nas:8443/`.
  - For CLI mounting via `davfs2`:
    ```bash
    sudo mount -t davfs http://rpi4nas:8080/ /mnt/nas -o uid=$(id -u),gid=$(id -g)
    ```

### 3. OpenWrt Web Admin Interface (LuCI)
Access the standard OpenWrt administrative interface on default ports:
- **URL**: `http://rpi4nas/` or `https://rpi4nas/`
- **Username**: `root`
- **Password**: Your configured `ROOT_PASSWORD`

---

## Storage & Permission Model

1. **Automatic Hotplug Mounting**:
   - When a USB storage drive is connected, `/etc/hotplug.d/block/10-mount` automatically mounts the active partition to `/mnt/sda1`.
   - Mount options: `rw,noatime` with filesystem-specific optimizations (`utf8=1`, `fmask=0002`, `dmask=0002`).
2. **Unmounted Protection**:
   - If the USB drive is unplugged or fails to mount, `/mnt/sda1` is set to `root:root 0700`.
   - WebDAV write attempts immediately fail with `500 Internal Server Error (Permission denied)` rather than writing files into the router's RAM overlay.
3. **Shared Ownership**:
   - Storage directories belong to `$NAS_USER:www-data` with mode `0775` and setgid enabled (`chmod g+s`).
   - All files created over WebDAV inherit the group `www-data` with permissions `0664`, allowing both the local Linux user and remote WebDAV users to read, edit, and delete each other's files.

---

## Remote Upgrades & Fail-Safe Recovery

Once deployed, the Raspberry Pi can be upgraded entirely over the network without taking down the device or risking a brick.

### Performing a Remote Upgrade
To deploy a newly built image from your computer to the remote appliance:
```bash
./scripts/remote_upgrade.sh <ip-or-tailscale-name>
```

#### What the Script Does Automatically:
1. Performs pre-flight health checks and verifies available space in remote `/tmp`.
2. Uploads `openwrt-*-squashfs-sysupgrade.img.gz` via SCP.
3. Validates the remote SHA-256 checksum and tests image compatibility (`sysupgrade -T`).
4. Arms the recovery trial watchdog (`nas-recovery arm-trial <build-id>`).
5. Initiates `sysupgrade -v` and monitors the reboot cycle.
6. Verifies that the new build ID is active and all core services (SSH, Tailscale, Lighttpd) are healthy before disarming the watchdog and committing the firmware.

### Autonomous Rollback on Failure
If an upgraded image has broken dependencies, failing network configurations, or broken services:
1. `nas-recovery` detects that core services are degraded.
2. It waits up to 45 seconds for stabilization.
3. If services do not recover, it executes pre-rollback failure diagnostics:
   - Captures `dmesg`, `logread`, `ps`, `netstat`, network interfaces, `lighttpd -tt`, and `tailscale status`.
   - Packages the report into `/recovery/rollback_reports/rollback-latest.tar.gz`.
   - Writes `/recovery/rollback_reports/rollback-summary.txt`.
4. Stages the recovery stock firmware image into RAM and restores the baseline stock firmware.
5. Reboots back into the working stock firmware autonomously.

### Diagnosing a Rollback
When `remote_upgrade.sh` reconnects after a rollback, it automatically:
- Detects the rollback event in `/recovery/recovery.log`.
- Downloads `rollback-summary.txt` and `rollback-latest.tar.gz`.
- Extracts all debug logs to `output/rollback_debug/`.
- Displays error highlights from `dmesg` and `logread` directly in your terminal.

You can also fetch the latest diagnostic report on demand at any time:
```bash
./scripts/remote_upgrade.sh --debug <ip-or-tailscale-name>
```

### Checking Appliance Status
To view live recovery storage status, stock firmware checksums, and service health:
```bash
./scripts/remote_upgrade.sh --status <ip-or-tailscale-name>
```

### Manual Rollback to Stock Firmware
To manually force the remote appliance to restore its factory baseline stock firmware:
```bash
./scripts/remote_upgrade.sh --revert <ip-or-tailscale-name>
```

---

## WiFi Failover Daemon Commands

You can interact with the WiFi failover service directly over SSH on the Raspberry Pi:

```bash
# Check current Ethernet link, active IP, and WiFi state
nas-wifi-failover status

# Trigger an immediate manual carrier check and failover scan
nas-wifi-failover check

# View service logs
logread | grep nas-wifi
```

---

## Security & Maintenance Best Practices

- **Zero Hardcoded Secrets**: Keep `.env` out of version control. The repository's `.gitignore` automatically blocks `.env`, `output/`, `*.pem`, `*.key`, `*.img`, and private host keys.
- **Dynamic First-Boot SSH Host Keys**: No private SSH host keys are baked into the firmware images. On initial boot, `ssh-keygen -A` uses the hardware random number generator (`/dev/hwrng`) to generate unique, cryptographically secure ED25519, ECDSA, and RSA host keys specifically for that hardware unit. This prevents server impersonation or Man-in-the-Middle attacks.
- **Host Key & Identity Persistence Across Upgrades**: Configured in `/etc/sysupgrade.conf` so that remote firmware upgrades automatically preserve `/etc/ssh/`, `/etc/lighttpd/ssl/`, and `/etc/tailscale/`. The appliance retains its cryptographic identity, SSH host fingerprint, SSL certificates, and Tailscale IP address across all future over-the-network upgrades without triggering client `known_hosts` warnings.
- **Authorized Key Security**: Keep your personal private keys secure on your client machines. Only client public keys (`.pub`) are injected into the build overlay.
- **MicroSD Card Longevity**: OpenWrt runs rootfs on SquashFS with a RAM/ext4 overlay, and temporary files (`/tmp`, `/var`) reside in RAM (`tmpfs`), minimizing write cycles to the microSD card.
- **TLS Certificate Auto-Renewal**: Certificates renewed by the ACME daemon trigger `/etc/acme-hook-lighttpd.sh`, which concatenates the key and certificate into `/etc/lighttpd/ssl/server.pem` and reloads Lighttpd without interrupting active connections.

---

## License

This project is licensed under the MIT License. OpenWrt packages and kernel modules are licensed under GPL-2.0 or their respective upstream licenses.
