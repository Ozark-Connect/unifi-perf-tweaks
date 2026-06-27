# mongodb-ssd-backup

**Script:** [`scripts/07-mongodb-ssd-backup.sh`](../scripts/07-mongodb-ssd-backup.sh)
**Compatibility:** Same as mongodb-ssd-offload (UCG models with NVMe SSD)
**Risk level:** Low - backup-only, does not modify the running database
**Depends on:** [`06-mongodb-ssd-offload.sh`](../scripts/06-mongodb-ssd-offload.sh) must be deployed first

> **Note on SSD mount paths:** Examples in this doc use `/volume1` for clarity, but the script auto-detects the SSD mount point. UniFi OS 5.0.x and earlier use `/volume1`; UniFi OS 5.1.7 EA and newer use `/volume/<uuid>/`. See [mongodb-ssd-offload.md](mongodb-ssd-offload.md) for details.

## Purpose

Once MongoDB is running on the SSD, the stock eMMC copy goes stale. This script installs a cron job that keeps current backups:

- **Daily at 1:30am:** `mongodump` to SSD (`/volume1/unifi-db-backup/`) - zero eMMC impact
- **Weekly (Sunday 1:35am):** `mongodump` to SSD + a compressed archive to eMMC (`/data/unifi/data/db-backup/unifi-db.archive.gz`)

The eMMC archive is **off-SSD insurance, not a boot fallback.** The daily backups live on the SSD, so if the SSD itself dies the eMMC archive is a recent (≤1 week old) copy to hand-restore from. It is a `mongodump` archive, not a live database - it is not auto-loaded. Zero-touch boot recovery is handled by [`06-mongodb-ssd-offload.sh`](../scripts/06-mongodb-ssd-offload.sh): if the SSD is absent it leaves MongoDB on the stock eMMC data directory, which mongod opens directly.

## Why Compress, and Dump to SSD First?

The daily backup goes to the SSD only - zero eMMC impact. The weekly eMMC archive is written with `mongodump --gzip --archive`, which is ~12x smaller than a raw dump (e.g. ~41MB vs ~485MB). That keeps both the eMMC write burst and the on-disk footprint small - important because the writable overlay on these models is space-constrained, and a large write burst risks the same eMMC GC stalls we're trying to avoid. The eMMC write lands during low-traffic hours.

## What the Script Does

The boot script:
1. Installs a backup script at `/data/unifi-db-ssd/backup.sh` (persists across reboots)
2. Creates a cron entry at `/etc/cron.d/mongodb-ssd-backup` (overlay, re-created each boot)

The backup script:
1. Runs `mongodump --port 27117` to SSD
2. If called with `--emmc`, also writes a compressed `mongodump --gzip --archive` to eMMC (clearing any legacy uncompressed dump left by older versions)

Logs go to `/tmp/mongodb-backup.log` (tmpfs, not eMMC).

## Manual Usage

```bash
# Run a backup now (SSD only)
/data/unifi-db-ssd/backup.sh

# Run a backup with eMMC failover copy
/data/unifi-db-ssd/backup.sh --emmc

# Check backup size
du -sh /volume1/unifi-db-backup/
du -sh /data/unifi/data/db-backup/unifi-db.archive.gz

# Check last backup log
cat /tmp/mongodb-backup.log

# Restore the eMMC archive (e.g. if the SSD died). Restores into the running
# mongod, overwriting current data - see docs/recovery.md for full recovery flows.
mongorestore --gzip --archive=/data/unifi/data/db-backup/unifi-db.archive.gz
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
