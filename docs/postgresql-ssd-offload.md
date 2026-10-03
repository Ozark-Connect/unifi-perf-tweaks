# postgresql-ssd-offload (EXPERIMENTAL)

**Script:** [`scripts/08-postgresql-ssd-offload.sh`](../scripts/08-postgresql-ssd-offload.sh)
**Compatibility:** UCG-Fiber and UCG-Max with UniFi Network 11.0.81 or later (PostgreSQL mode)
**Status:** **Experimental. Not yet run on a gateway.** Written from a tester's read-only findings on a UCG-Fiber running Network 11.0.81 ([NetworkOptimizer#1251](https://github.com/Ozark-Connect/NetworkOptimizer/issues/1251)) and from the PostgreSQL units in the UniFi OS 6.0.10 rootfs. Deploy only on a gateway you can factory reset, with a fresh console backup downloaded.
**Risk level:** Medium-high until verified. Moves the Network app database to a different device and stops the Network app at every boot.

This is the PostgreSQL counterpart of [mongodb-ssd-offload](mongodb-ssd-offload.md). Network 11.0.81 migrates the Network app from MongoDB to PostgreSQL, so `06-mongodb-ssd-offload.sh` no longer covers the live database.

## What changed in Network 11.0.81

The tester observed this on a UCG-Fiber after the upgrade:

- The Network app runs with `-Dunifi.active.db.mode=postgresql`.
- The database is `unifi-network` in a PostgreSQL 14 cluster on port **5434**. `SHOW data_directory` returns `/data/postgresql/14/apps/data`, which is on the eMMC.
- `unifi-mongodb.service` is inactive. Nothing listens on 27117.
- `06` and `07` are still in `/data/on_boot.d/`, and the stock `external-disk.conf` drop-in on `unifi-mongodb.service` is still present.

The cluster is not new in 11.0.81. UniFi OS 6.0.10 already ships its definition:

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
2. Reads `/etc/default/postgresql/14-apps` and checks that `postgresql.conf` points `data_directory` at `$DIR/data`. Any other layout aborts.
3. Waits for the cluster to accept connections, then lists its databases. It exits without changes if `unifi-network` is absent (Network app not on PostgreSQL yet), or if any other application database is present (shared cluster, not supported yet).
4. Waits up to 60 seconds for the SSD (`/volume1`, `/volume/<uuid>/`, or the `/dev/md3` mount).
5. Stops `unifi.service`, then `postgresql@14-apps.service`, and confirms the postmaster is gone.
6. On first run, copies `data/` to `<ssd>/postgresql-14-apps/` through a temp dir.
7. Sets the SSD dir to `postgres:postgres`, mode `0700`, and bind-mounts it over `/data/postgresql/14/apps/data`.
8. Starts the cluster and waits for it. If it does not come up on the SSD copy in 60 seconds, the script unmounts and starts it on the eMMC copy again.
9. Writes the marker `/data/unifi-pg-ssd/14-apps.ssd-active` and starts `unifi.service` plus any other active unit that depended on the cluster.

### Why only `data/` is bind-mounted

`/sbin/pg-cluster-setup` checks `$DIR/.configured` and the files in `$DIR/conf/`. If any is missing, it runs `rm -rf $DIR` and creates a new empty cluster. A bind mount over the whole cluster dir that came up without those files would delete the SSD copy. With only `data/` on the SSD, the files that `pg-cluster-setup` checks stay on the eMMC. The write load (`base/`, `pg_wal/`, checkpoints) moves with `data/`.

### Why a marker instead of an mtime check

`06` decides which MongoDB copy is current by comparing `WiredTiger.turtle` mtimes. That does not work for PostgreSQL. `postgresql@14-apps` starts on the eMMC copy at every boot, before `udm-boot` runs the script, and PostgreSQL rewrites `global/pg_control` on startup. The eMMC copy would look newer on every reboot, and an mtime check would overwrite the SSD data with the old eMMC snapshot each time.

The script uses the marker instead:

| Marker | SSD copy | Action |
|---|---|---|
| present | present | Bind the SSD copy. No copy. (Normal boot.) |
| absent | present | The eMMC copy is current. Move the SSD copy aside to `postgresql-14-apps.stale-<timestamp>` and re-migrate. |
| any | absent | Migrate from the eMMC copy. |

The script removes the marker on every path where PostgreSQL stays on the eMMC for that boot (no SSD, start failure, copy failure, and so on), because the eMMC copy then takes real writes. A previous SSD copy is never deleted, only moved aside.

**Limit:** if you delete the script without following [Reverting](#reverting), the marker stays. PostgreSQL then runs on the eMMC copy, and re-deploying the script later binds the older SSD copy over it. Follow the revert steps, which remove the marker.

### Known costs

- **Every boot stops and restarts the Network app**, same as `06`. The bind mount cannot go under a running PostgreSQL.
- **Writes in the boot window go to the eMMC copy and are hidden.** From cluster start to the bind mount (about one minute), the Network app writes to the eMMC copy. After the bind, the app restarts on the SSD copy and those writes are not visible. The eMMC copy remains a consistent cluster, because PostgreSQL is stopped cleanly before the bind.
- **No backup yet.** `07-mongodb-ssd-backup.sh` runs `mongodump` and does not cover PostgreSQL. If the SSD fails, the gateway falls back to the eMMC snapshot from the last migration. Keep a console backup (Settings > Control Plane > Backups), or take a manual dump (see [Manual backup](#manual-backup)).

## Before you test

### 1. Disable 06 and 07

On Network 11.0.81, `06` and `07` act on a MongoDB the app no longer uses. `06` still stops `unifi-mongodb.service` and restarts `unifi.service` at every boot. The effect of that on a PostgreSQL-mode app is not tested. Move both scripts out of the boot path and remove the backup cron. This keeps the MongoDB SSD copy in place as a reference.

```bash
mkdir -p /data/on_boot.d.disabled
mv /data/on_boot.d/06-mongodb-ssd-offload.sh /data/on_boot.d/07-mongodb-ssd-backup.sh /data/on_boot.d.disabled/
rm -f /etc/cron.d/mongodb-ssd-backup
```

The existing MongoDB bind mount (if mounted) stays until the next reboot. It is harmless, because `mongod` is not running.

### 2. Capture the baseline (read-only)

Send the output of these commands with your results. They answer the open questions below.

```bash
date -u; uptime -s
ubnt-device-info model_short; cat /usr/lib/version
dpkg-query -W unifi-native
cat /etc/default/postgresql/14-apps
ls -la /data/postgresql/14/apps /data/postgresql/14/apps/data
du -sh /data/postgresql/14/apps/data
df -h /data
findmnt /dev/md3
pg_lsclusters
runuser -u postgres -- psql -X -w -h /var/run/postgresql -p 5434 -d postgres \
  -Atc "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY 1;"
runuser -u postgres -- psql -X -w -h /var/run/postgresql -p 5434 -d postgres \
  -Atc "SELECT DISTINCT datname, usename, application_name FROM pg_stat_activity WHERE datname IS NOT NULL;"
systemctl cat unifi.service | grep -E '^(Requires|Wants|After|BindsTo|ExecStartPre)='
systemctl list-dependencies --reverse --plain postgresql@14-apps.service
systemctl is-enabled unifi-mongodb.service; systemctl is-active unifi-mongodb.service
grep -rs 'active.db.mode' /etc/default/unifi /usr/lib/unifi/data/system.properties
```

### 3. Measure eMMC writes before the change

The offload only helps if the Network app's PostgreSQL write load on the eMMC is significant. Take a sector count, wait one hour, take it again. Field 10 of `/proc/diskstats` is sectors written (512 bytes each).

```bash
date -u; awk '$3=="mmcblk0"{print $10}' /proc/diskstats
# one hour later
date -u; awk '$3=="mmcblk0"{print $10}' /proc/diskstats
```

Repeat the same measurement after the offload. The difference is the write load the offload removed.

## Deploying

```bash
scp scripts/08-postgresql-ssd-offload.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> chmod +x /data/on_boot.d/08-postgresql-ssd-offload.sh

# First run by hand. The Network app goes down for the copy.
ssh root@<gateway-ip> 'date -u; /data/on_boot.d/08-postgresql-ssd-offload.sh; date -u'
```

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

Then reboot once and check the same items. The second run takes the "SSD copy is authoritative" path with no copy.

## Reverting

**Follow this order. Do not delete the SSD copy until the Network app works on the eMMC.**

This path copies the current SSD data back to the eMMC, so no data is lost. Check `df -h /data` first: the eMMC needs room for a second copy of `data/` until step 8.

```bash
# 1. Stop the Network app, then the cluster
systemctl stop unifi.service
systemctl stop postgresql@14-apps.service
pg_lsclusters
# 14 apps must show "down". If not, stop here.

# 2. Unmount the bind mount (shows the old eMMC copy underneath)
umount /data/postgresql/14/apps/data

# 3. Remove the boot script and the marker
rm -f /data/on_boot.d/08-postgresql-ssd-offload.sh /data/unifi-pg-ssd/14-apps.ssd-active

# 4. Keep the old eMMC copy aside, copy the current SSD copy in
SSD_PG_DIR="$(findmnt -no TARGET /dev/md3 | head -1)/postgresql-14-apps"
mv /data/postgresql/14/apps/data /data/postgresql/14/apps/data.pre-revert
mkdir /data/postgresql/14/apps/data
cp -a "$SSD_PG_DIR"/. /data/postgresql/14/apps/data/
chown postgres:postgres /data/postgresql/14/apps/data
chmod 0700 /data/postgresql/14/apps/data

# 5. Start the cluster, then the Network app
systemctl start postgresql@14-apps.service
systemctl start unifi.service

# 6. Confirm both are healthy
systemctl is-active postgresql@14-apps unifi

# 7. Check the Network UI shows current data

# 8. Only then remove the old eMMC copy
rm -rf /data/postgresql/14/apps/data.pre-revert
```

To revert to the pre-migration eMMC copy instead (loses all changes since the migration), skip step 4.

### Recovering from a moved-aside copy

If a fallback boot caused a re-migration, the previous SSD copy is in `<ssd>/postgresql-14-apps.stale-<timestamp>`. To use it: stop the stack and unmount as in steps 1-2, move `<ssd>/postgresql-14-apps` aside, rename the `.stale-` dir to `postgresql-14-apps`, and run the script again. Delete `.stale-` dirs you do not need, as nothing cleans them up.

## Manual backup

Until a `07`-style backup script exists, take a custom-format dump to the SSD:

```bash
SSD="$(findmnt -no TARGET /dev/md3 | head -1)"
mkdir -p "$SSD/unifi-pg-backup"
runuser -u postgres -- pg_dump -h /var/run/postgresql -p 5434 -Fc unifi-network \
  > "$SSD/unifi-pg-backup/unifi-network.dump"
```

Restore it with `pg_restore --clean --if-exists -d unifi-network` while `unifi.service` is stopped. The restore path is untested.

## Open questions

These need answers from a live gateway before the script can leave experimental status:

- **Does `unifi.service` in 11.0.81 declare a dependency on `postgresql@14-apps.service`?** The script restarts the Network app either way, but a `Requires=` changes how the stop propagates.
- **Is the `apps` cluster shared?** The name suggests other apps can use it. The script refuses if it finds any database other than `unifi-network`.
- **What does `06` do on a PostgreSQL-mode boot?** It stops `unifi-mongodb.service` and starts `unifi.service`. If `unifi.service` still `Requires=unifi-mongodb.service`, that start brings `mongod` back. This is why `06` and `07` are disabled for the test. A follow-up change can make `06` and `07` exit when the Network app is on PostgreSQL, once the signal for that mode is known.
- **How large is the eMMC write load from PostgreSQL?** With `synchronous_commit=off` and `wal_writer_delay=10000ms`, the cluster batches WAL writes. The flow-audit bulk deletes that hurt MongoDB may produce a different pattern here (autovacuum, checkpoints). The before and after measurement answers this.
- **What happens on a PostgreSQL major upgrade?** The firmware ships PostgreSQL 16 binaries and `postgresql-cluster-14-*-upgrade` units for other clusters. An upgrade of the `apps` cluster to 16 would create a new cluster under `/data/postgresql/16/apps` on the eMMC, and the script (configured for `14-apps`) would stop matching. The expected result is a silent fallback to the eMMC, not data loss, but it is not tested.
- **UCG-Max:** same model check as `06`, not tested.

## What to report back

- The baseline output from [Before you test](#2-capture-the-baseline-read-only).
- The script output from the first manual run and from the first reboot (`journalctl -t postgresql-ssd-offload -b`).
- The verification output.
- The eMMC sector counts before and after.
- Anything wrong in the Network UI after the migration (missing clients, stats, settings).
