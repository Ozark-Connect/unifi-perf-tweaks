# Prerequisites

> **Important:** These scripts were developed and tested on a **UCG-Fiber**. If you're running a different model (UDM-Pro, UDM-SE, UCG-Max, etc.), verify all device paths, mount points, and service names before deploying. See the [Verify Your Device](#verify-your-device) section below.

## SSH Access

You need root SSH access to your gateway:

1. Open your UniFi Console at `https://<gateway-ip>`, `https://unifi.ui.com`, or the mobile app
2. Go to **Settings > Control Plane > Console**
3. Enable **SSH** and set a secure password
4. Connect: `ssh root@<gateway-ip>` (username is `root`)

## Install udm-boot

These scripts run from `/data/on_boot.d/`, but **that directory doesn't do anything by itself**. You need [udm-boot](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) - a systemd service that executes scripts in `/data/on_boot.d/` on every boot. It doesn't ship with the gateway; you have to install it.

### Install (Recommended)

SSH into your gateway and run these commands. This creates the udm-boot systemd service directly - no downloads, no package manager, works on all current UDM/UCG devices:

```bash
cat > /etc/systemd/system/udm-boot.service << 'EOF'
[Unit]
Description=Run On Startup UDM 2.x and above
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=500
StartLimitBurst=1

[Service]
Type=oneshot
ExecStart=bash -c 'mkdir -p /data/on_boot.d && find -L /data/on_boot.d -mindepth 1 -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r -n 1 -- sh -c '\''if test -x "$0"; then echo "%n: running $0"; "$0"; else case "$0" in *.sh) echo "%n: sourcing $0"; . "$0";; *) echo "%n: ignoring $0";; esac; fi'\'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /data/on_boot.d
systemctl daemon-reload
systemctl enable udm-boot
systemctl start udm-boot
```

This is the same service definition used by the upstream [unifios-utilities](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) project, copied verbatim. Creating the service file directly is the most reliable approach - no network dependency, no package manager, and you can see exactly what's being installed.

### Alternative: Upstream Remote Install Script

The [unifios-utilities](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) project provides a remote install script that handles device detection and installs udm-boot for you. It's a sound script that supports all current UDM/UCG models, but it requires your gateway to reach GitHub and it also installs CNI plugins and a CNI bridge script that you don't need for these perf tweaks.

```bash
curl -fsL "https://raw.githubusercontent.com/unifi-utilities/unifios-utilities/HEAD/on-boot-script-2.x/remote_install.sh" | /bin/bash
```

### Verify Installation

```bash
systemctl status udm-boot
```

You should see `active (running)` and `enabled`. If not, check logs with `journalctl -u udm-boot -n 50`.

### How It Works

- udm-boot runs as a systemd service on every boot
- It executes scripts in `/data/on_boot.d/` **alphabetically by filename**
- Only files with the `.sh` extension and the executable bit set are run
- The `/data` partition is persistent - scripts survive firmware updates and reboots
- Scripts run as root during the boot process

### After Firmware Updates

udm-boot usually survives firmware updates, but verify after major UniFi OS upgrades:

```bash
systemctl status udm-boot
```

If it's gone, reinstall it using the steps above. Your scripts in `/data/on_boot.d/` will still be there - they just need udm-boot to execute them.

### Removing udm-boot

If you need to remove udm-boot entirely:

```bash
systemctl stop udm-boot
systemctl disable udm-boot
rm /etc/systemd/system/udm-boot.service
systemctl daemon-reload
```

This leaves your scripts in `/data/on_boot.d/` intact, they just won't run on boot anymore. Remove them manually if you want a clean slate:

```bash
rm /data/on_boot.d/*.sh
```

## Installation

```bash
# Copy a script to the gateway
scp scripts/10-journald-volatile.sh root@<gateway-ip>:/data/on_boot.d/

# Make it executable
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/10-journald-volatile.sh"

# Test run it (safe to run while the gateway is live)
ssh root@<gateway-ip> /data/on_boot.d/10-journald-volatile.sh
```

### Deploying Multiple Scripts

Copy them one at a time and test each before adding the next:

```bash
# Deploy and test journald first
scp scripts/10-journald-volatile.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/10-journald-volatile.sh"
ssh root@<gateway-ip> /data/on_boot.d/10-journald-volatile.sh

# Monitor for 24 hours, then add JVM tuning
scp scripts/11-jvm-heap-tuning.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/11-jvm-heap-tuning.sh"
ssh root@<gateway-ip> /data/on_boot.d/11-jvm-heap-tuning.sh
```

## Boot Order

Scripts are numbered to run in a sensible order. If you have existing scripts in `/data/on_boot.d/`, you may need to renumber to avoid conflicts. See the [README](../README.md#boot-order) for dependency details.

## Firmware Compatibility

| Component | UniFi Network Upgrade | UniFi OS Upgrade | Factory Reset |
|---|---|---|---|
| udm-boot service | Preserved | **Verify** | **Reinstall** |
| Scripts in `/data/on_boot.d/` | Preserved | Preserved | **Wiped** |
| `/etc/default/unifi` (JVM settings) | Preserved | **Reset to stock** | **Reset** |
| `/etc/systemd/journald.conf` | Preserved | **Reset to stock** | **Reset** |
| SSD data (`/volume1/unifi-db/`) | Preserved | Preserved | **May be wiped** |
| `config.fan` (fan settings) | Preserved until uhwd restart | **Reset** | **Reset** |

Boot scripts reapply all overlay settings on every boot, so UniFi OS upgrades are handled automatically. After a factory reset, you need to reinstall udm-boot and re-deploy the scripts.

## Physical Access

**Always have physical access to your gateway when testing boot scripts.** If a script causes a boot loop or other issue, you need to be able to:

1. Connect a monitor/keyboard (if supported) or serial console
2. Factory reset via the reset button
3. Re-flash firmware via USB recovery

Don't deploy boot scripts to a gateway you can't physically reach.

## Verify Your Device

These scripts were tested on a UCG-Fiber. If you're on a different model, SSH in and run these commands **before deploying anything:**

```bash
# 1. Check eMMC device path (scripts reference /dev/mmcblk0)
lsblk

# 2. Check SSD mount point (scripts assume /volume1)
mount | grep -E "md|nvme|sd"

# 3. Check MongoDB data path (scripts assume /data/unifi/data/db)
ls -la /data/unifi/data/db/

# 4. Check fan PID categories (varies by model)
python3 -c "
import json, threading, time
from ustd.statusdb.sdb_client import SDBClient
c = SDBClient()
t = threading.Thread(target=c.run, daemon=True); t.start(); time.sleep(1)
fan = c.get('config.fan')
print(json.dumps(fan, indent=2))
"

# 5. Check JVM config path
cat /etc/default/unifi | grep UNIFI_NATIVE

# 6. Check journald config
cat /etc/systemd/journald.conf
```

If any paths or device names differ from what the scripts expect, update the variables at the top of the relevant script before deploying. For SSD scripts specifically: UDM-Pro models often mount storage at `/mnt/data` or `/data_ext` rather than `/volume1`.
