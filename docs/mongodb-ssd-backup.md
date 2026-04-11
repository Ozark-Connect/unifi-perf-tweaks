# mongodb-ssd-backup

**Script:** [`scripts/21-mongodb-ssd-backup.sh`](../scripts/21-mongodb-ssd-backup.sh)
**Compatibility:** Same as mongodb-ssd-offload (UCG models with NVMe SSD)
**Risk level:** Low - backup-only, does not modify the running database
**Depends on:** [`20-mongodb-ssd-offload.sh`](../scripts/20-mongodb-ssd-offload.sh) must be deployed first

> **Note on SSD mount paths:** Examples in this doc use `/volume1` for clarity, but the script auto-detects the SSD mount point. UniFi OS 5.0.x and earlier use `/volume1`; UniFi OS 5.1.7 EA and newer use `/volume/<uuid>/`. See [mongodb-ssd-offload.md](mongodb-ssd-offload.md) for details.

## Purpose

Once MongoDB is running on the SSD, the eMMC copy goes stale. This script installs a cron job that keeps a backup current:

- **Daily at 1:30am:** `mongodump` to SSD (`/volume1/unifi-db-backup/`) - zero eMMC impact
- **Weekly (Sunday 1:35am):** `mongodump` to SSD + copy to eMMC (`/data/unifi/data/db-backup/`) as a failover safety net

The eMMC copy is a hot spare. If the SSD mount fails for any reason, MongoDB falls back to eMMC data that's at most 1 week old.

## Why Dump to SSD First?

A direct `mongodump` to eMMC writes ~453MB in 11 seconds - a massive burst that risks triggering the same eMMC GC stalls we're trying to avoid. Dumping to SSD first has virtually zero eMMC impact. The weekly eMMC copy is acceptable during low-traffic hours.

## What the Script Does

The boot script:
1. Installs a backup script at `/data/unifi-db-ssd/backup.sh` (persists across reboots)
2. Creates a cron entry at `/etc/cron.d/mongodb-ssd-backup` (overlay, re-created each boot)

The backup script:
1. Runs `mongodump --port 27117` to SSD
2. If called with `--emmc`, copies the SSD dump to eMMC

Logs go to `/tmp/mongodb-backup.log` (tmpfs, not eMMC).

## Manual Usage

```bash
# Run a backup now (SSD only)
/data/unifi-db-ssd/backup.sh

# Run a backup with eMMC failover copy
/data/unifi-db-ssd/backup.sh --emmc

# Check backup size
du -sh /volume1/unifi-db-backup/
du -sh /data/unifi/data/db-backup/

# Check last backup log
cat /tmp/mongodb-backup.log
```

## Cron Persistence

The cron file lives on the overlay (`/etc/cron.d/`) and is lost on reboot. The boot script re-creates it every boot. This is by design - it keeps the cron schedule in sync with the script.

## Reverting

```bash
# Remove cron
rm /etc/cron.d/mongodb-ssd-backup

# Remove backup script
rm -rf /data/unifi-db-ssd/

# Remove backup data (optional)
rm -rf /volume1/unifi-db-backup/
rm -rf /data/unifi/data/db-backup/
```

Remove the script from `/data/on_boot.d/` to prevent re-installation on next boot.
