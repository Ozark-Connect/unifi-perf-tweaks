# postgresql-ssd-offload

**Script:** [`scripts/08-postgresql-ssd-offload.sh`](../scripts/08-postgresql-ssd-offload.sh)
**Compatibility:** UCG-Fiber/UCG-Max with NVMe SSD, PostgreSQL `14/apps`, port **5434**, UniFi Network in PostgreSQL mode. UCG-Max has not been hardware-verified.
**Risk level:** Medium - moves database I/O to a different device. Missing-SSD fallback may use stale eMMC data; it is not lossless recovery.

This is the PostgreSQL counterpart of [mongodb-ssd-offload](mongodb-ssd-offload.md). Network 11.0.81 migrates the Network app from MongoDB to PostgreSQL, so `06-mongodb-ssd-offload.sh` no longer covers the live database.

## Supported layout

Network must run in PostgreSQL mode (`-Dunifi.active.db.mode=postgresql`). The supported cluster layout is:

| Item | Value |
|---|---|
| Cluster definition | `/etc/default/postgresql/14-apps`: `DIR=/data/postgresql/14/apps`, `CLUSTER_PORT=5434`, `CLUSTER_ARGS="-o synchronous_commit=off -o wal_writer_delay=10000ms"` |
| Server unit | `postgresql@14-apps.service` (`pg_ctlcluster`, stops with `-m fast`), `Slice=app-db.slice` |
| Setup unit | `postgresql-cluster@14-apps.service`, oneshot, runs `/sbin/pg-cluster-setup` |
| On-disk layout | `/data/postgresql/14/apps/{.configured,conf/,data/}`. `/etc/postgresql/14/apps` is a symlink to `conf/`. |
| Stats temp | `/var/run/postgresql/14-apps.pg_stat_tmp` (tmpfs already) |

The UniFi OS core cluster (`14-main`, port 5432, `unifi-core`) is a separate cluster under `/data/postgresql/14/main`. This script does not touch it.

## What the script does

1. Model check: UCG-Fiber and UCG-Max only (same rule as `06`).
2. Takes a nonblocking run lock and validates PostgreSQL `14/apps`, port `5434`, configuration and the running data directory. Other layouts, PGDATA symlinks (including external WAL/tablespaces), and shared clusters are unsupported.
3. Waits up to 60 seconds for both connection readiness and an active apps systemd unit before checking identity and listing databases. Without an authority marker, an absent `unifi-network` database means there is nothing to offload.
4. Waits up to 60 seconds for the SSD (`/volume1`, `/volume/<uuid>/`, or the `/dev/md3` mount). If missing and PGDATA is unmounted, leaves services unchanged on eMMC and warns about stale data.
5. Stops `unifi.service`, then `postgresql@14-apps.service`, and confirms the postmaster is gone.
6. On first run, copies `data/` to `<ssd>/postgresql-14-apps/` through a temp dir.
7. Sets the SSD dir to `postgres:postgres`, mode `0700`, and bind-mounts it over `/data/postgresql/14/apps/data`.
8. Persists the copied data and authority marker `/data/unifi-pg-ssd/14-apps.ssd-active` before starting PostgreSQL on SSD.
9. Checks PostgreSQL readiness and identity, then starts Network and the previously active application dependents. Critical operations are checked; errors and catchable interrupts enter the same recovery path.

### Why only `data/` is bind-mounted

`/sbin/pg-cluster-setup` checks `$DIR/.configured` and the files in `$DIR/conf/`. If any is missing, it runs `rm -rf $DIR` and creates a new empty cluster. A bind mount over the whole cluster dir that came up without those files would delete the SSD copy. With only `data/` on the SSD, the files that `pg-cluster-setup` checks stay on the eMMC. The write load (`base/`, `pg_wal/`, checkpoints) moves with `data/`.

### Why a marker instead of an mtime check

`06` decides which MongoDB copy is current by comparing `WiredTiger.turtle` mtimes. That does not work for PostgreSQL. `postgresql@14-apps` starts on the eMMC copy at every boot, before `udm-boot` runs the script, and PostgreSQL rewrites `global/pg_control` on startup. The eMMC copy would look newer on every reboot, and an mtime check would overwrite the SSD data with the old eMMC snapshot each time.

The script uses the marker instead:

| Marker | SSD copy | Action |
|---|---|---|
| present | present | Bind the SSD copy. No copy, including after missing-SSD fallback. |
| absent | present | The eMMC copy is current. Move the SSD copy aside to `postgresql-14-apps.stale-<timestamp>` and re-migrate. |
| absent | absent | Migrate from the eMMC copy. |
| present | SSD mount unavailable | Leave unmounted eMMC operation unchanged, retain authority and warn. |
| present | SSD mounted but copy invalid/missing | Log an error and change no services. Do not replace newer data with the eMMC snapshot. Manual recovery required. |

Missing-SSD fallback favors availability, like `06`: the exposed eMMC database may be the original offload snapshot. When SSD returns, the next run rebinds the marked SSD copy automatically. Writes made only on eMMC during fallback are hidden, not merged or copied onto SSD; the underlying eMMC directory remains intact. A missing SSD underneath an existing bind is an error, not a live switch to eMMC.

Failure handling depends on where the run fails. Previous SSD copies are always preserved.

| Failure point | Result |
|---|---|
| Before the script stops the stack (layout, readiness, database list, marker checks) | No service changes. Network keeps running on the copy it has. The marker is kept, and the next run retries. |
| After the stop, during a first migration | Recover to eMMC after a confirmed shutdown, a successful unmount (if needed) and a durable marker removal. |
| After the stop, with SSD authority | Marker kept, stack left stopped for manual recovery. |
| After PostgreSQL is verified on the SSD (application start fails) | PostgreSQL stays up on the SSD. Start the applications manually. |

An existing, verified bind exits before any database check. A rerun on an offloaded gateway, for example a Network Optimizer redeploy, never stops services.

**Limit:** this is not a boot interlock and installs no systemd hooks. Firmware may start Network on eMMC before late binding. Lock contention exits without changing services; skipped hooks and power loss can likewise expose stale eMMC data. Do not clear authority merely to get the app running.

### Known costs

- **Migration and offload boots stop and restart Network.** The bind mount cannot go under a running PostgreSQL.
- **Boot-window writes can be lost.** Network writes to eMMC before rebinding are hidden afterward; the window depends on firmware boot ordering.
- **Fallback can expose stale settings/history.** Returning SSD ends fallback on the next successful run and hides fallback-only writes. `09` preserves old archives until the authoritative bind is restored; neither fallback nor rebinding is lossless recovery.
- **Backups need separate verification.** `07` does not cover PostgreSQL; [09](postgresql-ssd-backup.md) provides daily SSD/weekly eMMC archives. Neither an SSD-local dump nor the old eMMC snapshot is a current off-device backup.
- **Total eMMC writes may not drop.** Moving PostgreSQL does not move application logs, the UniFi OS core cluster (`14/main`), firmware activity or other eMMC workloads. One field measurement (UCG-Fiber, Network 11.0.81, matched ~10.5 h windows) showed no drop in total `mmcblk0` writes after the offload: about 140 MiB/h before and 168 MiB/h after. Attribution of the remaining writes is open.

## Requirements

Require physical recovery access, a downloaded Console backup, a verified [off-device PostgreSQL backup](#manual-backup), and a maintenance window for the Network restart. The SSD needs space for a new PGDATA copy while retaining any previous copy. Confirm `unifi-network` is the only application database in `14/apps`; shared clusters and external WAL/tablespaces are unsupported.

[09](postgresql-ssd-backup.md) can capture the pre-offload backup while PostgreSQL is still on eMMC. Copy the archive off-device and verify a restore before migration.

### Retiring the MongoDB hooks

Moving `06` and `07` aside is not enough. While `06` is active, the current MongoDB data is on the SSD, and the eMMC copy under the bind mount is the snapshot from the first migration (5 months old on one production gateway). After the next reboot, the Network app's on-demand `mongod`, or a downgrade to Network 10.x, would find that old snapshot.

Use [`scripts/maintenance/mongodb-ssd-decommission.sh`](../scripts/maintenance/mongodb-ssd-decommission.sh) `--decommission`. It confirms the PostgreSQL backend, puts the newest MongoDB copy back on the eMMC, retires the hooks, cron and helper, restarts Network and deletes the SSD copies. See [mongodb-ssd-offload.md](mongodb-ssd-offload.md#decommissioning-after-the-postgresql-migration). Run it before you install `08`. Both stop `unifi.service`, so never run them at the same time.
### Check the layout

Confirm the database, space, SSD mount and service dependencies before installation:

```bash
cat /etc/default/postgresql/14-apps
du -sh /data/postgresql/14/apps/data
df -h /data
findmnt /dev/md3
pg_lsclusters
runuser -u postgres -- psql -X -w -h /var/run/postgresql -p 5434 -d postgres \
  -Atc "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY 1;"
systemctl cat unifi.service | grep -E '^(Requires|Wants|After|BindsTo|ExecStartPre)='
systemctl list-dependencies --reverse --plain postgresql@14-apps.service
ps -o args= -C unifi | tr ' ' '\n' | grep active.db.mode
```

Measure eMMC sectors written before and after over comparable intervals: `date -u; awk '$3=="mmcblk0"{print $10}' /proc/diskstats` (512 bytes per sector). PostgreSQL may not reproduce MongoDB's write-pressure pattern.

## Installation

Run the first migration manually before enabling boot persistence. The script takes **no arguments**, including `--dry-run`, and must be executed with Bash rather than sourced.

```bash
scp scripts/08-postgresql-ssd-offload.sh root@<gateway-ip>:/data/08-postgresql-ssd-offload.sh
ssh root@<gateway-ip> 'bash /data/08-postgresql-ssd-offload.sh'
```

After verifying the migration, install executable boot hooks in order:

```bash
ssh root@<gateway-ip> 'install -o root -g root -m 0700 /data/08-postgresql-ssd-offload.sh /data/on_boot.d/08-postgresql-ssd-offload.sh'
```

Install [09](postgresql-ssd-backup.md#installation-and-manual-use) afterward to recreate the backup cron at boot. The existing `udm-boot` service must be enabled; see [prerequisites](prerequisites.md).

The script logs to stdout and to syslog with tag `postgresql-ssd-offload` (`journalctl -t postgresql-ssd-offload`).

## Verification

```bash
# Bind mount is active and comes from the SSD
findmnt /data/postgresql/14/apps/data
# SOURCE should be the SSD device, e.g. /dev/md3[/postgresql-14-apps]

# PostgreSQL reports the stock path (the bind mount is transparent to it)
runuser -u postgres -- psql -X -w -h /var/run/postgresql -p 5434 -d unifi-network -Atc 'SHOW data_directory;'

# Marker present
cat /data/unifi-pg-ssd/14-apps.ssd-active

# Network app is up and on PostgreSQL
systemctl is-active postgresql@14-apps unifi
ps -o args= -C unifi | tr ' ' '\n' | grep active.db.mode

# Writes go to the SSD copy: pg_wal files update in the last few minutes
ls -lt /data/postgresql/14/apps/data/pg_wal | head -5
```

Check that `14/main` is unchanged and Network shows current settings, clients and history. A manual rerun verifies the existing bind and marker and exits without stopping services or copying data.

Boot hooks must be **executable**. A non-executable `.sh` may be sourced by the runner, which is unsupported. To retire a hook, archive it outside the boot directory rather than changing its executable bit.

## Firmware Upgrade Safety

- **UniFi Network upgrades:** An intact bind keeps database schema changes on SSD. Changes to the database backend or cluster layout require compatibility review.
- **UniFi OS upgrades:** `/data/on_boot.d/`, the authority marker and SSD data persist. The boot hook reapplies the bind, and `09` reinstalls the backup cron. Keep a fresh off-device backup before upgrading.
- **Upgrades that change the cluster:** The script rejects unsupported layouts but cannot protect migrations that firmware performs before the hook runs. Revert before an upgrade that changes PostgreSQL version, paths or setup behavior.
- **SSD missing at boot/manual execution:** With unmounted PGDATA, services are left unchanged on eMMC. Authority is retained, and the next successful run rebinds SSD without copying fallback eMMC data. Without authority, initial migration is skipped. An SSD failure while already bound does not automatically switch to eMMC.
- **Factory reset:** Wipes `/data`, including the marker and the eMMC copy. If the SSD copy survives, the next run finds no marker and moves it aside to a `.stale-` dir before it migrates the new eMMC data. Nothing is overwritten.

## Reverting

**Follow this order. Do not delete the SSD copy until the Network app works on the eMMC.**

Copy the current, readable SSD data back; do not select the old eMMC snapshot unless explicitly accepting loss of all later changes. Check `df -h /data` first: eMMC needs room for a second copy. Use the verified SSD mount below. Run as one Bash block; any failure must leave services stopped for investigation. Do not reboot mid-revert.

```bash
bash <<'EOF'
set -euo pipefail
SSD_MOUNT="/volume/<verified-uuid>" # Or /volume1; confirm with findmnt.
SSD_PG_DIR="$SSD_MOUNT/postgresql-14-apps"
PG_DATA=/data/postgresql/14/apps/data
STATE_DIR=/data/unifi-pg-ssd
test -f "$SSD_PG_DIR/global/pg_control"
test "$(cat "$SSD_PG_DIR/PG_VERSION")" = 14
exec 9>/run/postgresql-ssd-offload.lock
flock -n 9
systemctl stop unifi.service
systemctl stop postgresql@14-apps.service
test ! -e "$PG_DATA/postmaster.pid"
case "$(systemctl is-active postgresql@14-apps.service)" in
    inactive|failed) ;;
    *) echo "Cluster not stopped; aborting" >&2; exit 1 ;;
esac
if mountpoint -q "$PG_DATA"; then
    test "$(stat -c '%d:%i' "$PG_DATA")" = "$(stat -c '%d:%i' "$SSD_PG_DIR")"
    umount "$PG_DATA"
fi
ARCHIVE="/data/on_boot.d.disabled/postgresql-$(date +%Y%m%d%H%M%S)-$$"
mkdir -p "$ARCHIVE"
if [ -f /data/on_boot.d/08-postgresql-ssd-offload.sh ]; then
    mv /data/on_boot.d/08-postgresql-ssd-offload.sh "$ARCHIVE/"
fi
NEW_DATA=$(mktemp -d "$PG_DATA.revert.XXXXXX")
cp -a "$SSD_PG_DIR"/. "$NEW_DATA"/
chown postgres:postgres "$NEW_DATA"
chmod 0700 "$NEW_DATA"
sync -f "$NEW_DATA"
OLD_DATA="$PG_DATA.pre-revert-$(date +%Y%m%d%H%M%S)-$$"
test ! -e "$OLD_DATA"
mv -T "$PG_DATA" "$OLD_DATA"
mv -T "$NEW_DATA" "$PG_DATA"
sync -f "$PG_DATA"
rm -f "$STATE_DIR/14-apps.ssd-active"
sync -f "$STATE_DIR"
systemctl start postgresql@14-apps.service
runuser -u postgres -- psql -X -w -v ON_ERROR_STOP=1 -h /var/run/postgresql -p 5434 \
    -d unifi-network -Atc 'SELECT 1;'
systemctl start unifi.service
systemctl is-active --quiet postgresql@14-apps.service
systemctl is-active --quiet unifi.service
printf 'Reverted; previous eMMC data retained at %s. Verify Network UI and 14/main.\n' "$OLD_DATA"
EOF
```

Keep the SSD copy and previous eMMC copy until application-level verification passes. Reverting to the pre-migration snapshot is a separate, explicitly lossy recovery decision.

### Recovering from a moved-aside copy

Choose the copy deliberately; there is no automatic merge of SSD and eMMC histories. Under the same run lock, stop Network and `14/apps`, confirm the postmaster exited, and unmount the verified bind. Preserve the current SSD directory under a new name before renaming the selected `.stale-*` copy to `postgresql-14-apps`.

Validate its PostgreSQL version, ownership and layout, then bind it directly over PGDATA. Write the marker identifying that canonical SSD path through a temporary file, sync it, rename it to `14-apps.ssd-active`, and sync the state filesystem **before** starting PostgreSQL. Start `postgresql@14-apps.service` directly, verify it at socket `/var/run/postgresql`, port `5434`, then start Network. Do not invoke `08` while PostgreSQL is stopped: its initial database gate requires a running cluster. A later rerun will verify the bind and marker.

## Manual backup

Use a completed [09 archive](postgresql-ssd-backup.md), copied off-device and restore-verified, or stream a custom-format dump and apps-cluster globals to a protected directory **on another machine**. Globals can contain password hashes; do not post dumps in issues. Also download a Console backup and save cluster config/service definitions.

```bash
# On the backup machine, in a private backup directory:
bash <<'EOF'
set -e
umask 077
ssh root@<gateway-ip> 'runuser -u postgres -- pg_dump --cluster 14/apps -w -h /var/run/postgresql -p 5434 -Fc unifi-network' \
  > unifi-network.dump.tmp
mv unifi-network.dump.tmp unifi-network.dump
ssh root@<gateway-ip> 'runuser -u postgres -- pg_dumpall --cluster 14/apps -w -h /var/run/postgresql -p 5434 --globals-only' \
  > apps-globals.sql.tmp
mv apps-globals.sql.tmp apps-globals.sql
EOF
```

Check command exit status, checksum the completed files, and verify a restore into an isolated compatible PostgreSQL instance with the required roles/owners. Listing the dump is not a restore test. Do not blindly replay globals into existing roles.

To restore to the existing apps database, stop Network but keep PostgreSQL running, confirm the target and roles, and use a dump readable by the PostgreSQL OS user:

```bash
runuser -u postgres -- pg_restore --cluster 14/apps -h /var/run/postgresql -p 5434 --exit-on-error \
  --single-transaction --clean --if-exists -d unifi-network /path/to/unifi-network.dump
```

Validate application data before restarting Network. Never target port `5432`. A verified isolated database restore does not establish full gateway application recovery.
