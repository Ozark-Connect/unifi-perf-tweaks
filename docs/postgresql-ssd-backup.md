# postgresql-ssd-backup

**Script:** [`scripts/09-postgresql-ssd-backup.sh`](../scripts/09-postgresql-ssd-backup.sh)
**Compatibility:** UCG-Fiber/UCG-Max, PostgreSQL `14/apps`, port **5434**, database `unifi-network`.
**Risk level:** Low - backup-only, does not modify the running database.
**Depends on:** SSD mounted; `08` is not required while the database is on eMMC.

## Purpose

This is the PostgreSQL counterpart of [mongodb-ssd-backup](mongodb-ssd-backup.md). It installs a persistent helper and recreates its cron each boot:

- **Daily at 1:30am:** database and roles/globals backup to SSD.
- **Sunday at 1:30am:** the same backup plus a compressed eMMC archive.

Times are gateway local time. Installation takes an initial SSD/eMMC backup if either archive fails content/checksum validation.

**09 can precede 08.** It dumps the running database, whether PGDATA is on eMMC or SSD. It never stops services, changes mounts, copies PGDATA, or touches `14/main`. It shares 08's nonblocking operation lock; a concurrent offload, revert or backup causes a logged failure instead of waiting.

An SSD-authority marker requires a matching, active PGDATA bind. An unmarked PGDATA mount is also rejected. Availability-first fallback can leave Network running on stale eMMC, but `09` must not replace good archives with that database. Once SSD returns and `08` restores the authoritative bind, backups resume normally. This check does not hold Network stopped or eliminate `08`'s boot-window risk.

## Backup contents and destinations

Each completed backup contains:

- `unifi-network.dump`: custom-format database dump.
- `apps-globals.sql`: apps-cluster roles and globals, including password hashes.
- `SHA256SUMS` and UTC `completed-at`.

| Item | Path |
|---|---|
| Generated helper | `/data/unifi-pg-ssd/backup.sh` |
| Cron | `/etc/cron.d/postgresql-ssd-backup` |
| SSD archive | `<ssd>/unifi-pg-backup/unifi-pg.tar` |
| Weekly eMMC archive | `/data/unifi-pg-backup/unifi-pg.tar.gz` |
| Cron output | `/tmp/postgresql-backup.log` |
| Syslog tag | `postgresql-ssd-backup` |

The custom-format dump is already compressed. The weekly gzip wraps the same completed SSD tar; it does not query the database a second time. Daily runs do not update the eMMC archive.

Archive publication uses checked temporary files and same-filesystem renames. Failed dumps/packing leave the old SSD archive intact; failed weekly compression leaves the old eMMC archive intact. One latest archive is retained at each destination, like `07`, not a multi-generation backup history. Allow SSD space for the old archive, staging files and new archive, and eMMC space for old and new compressed archives during replacement.

Private directories are mode `0700`, archives `0600`. Installer validation checks each archive's nonempty database/globals files, stored checksums, timestamp format and `pg_restore --list`. Archives may have different recovery points; validation neither requires freshness nor proves restorability. Globals and the database are separate snapshots; avoid changing roles during capture. Checksums detect file corruption, not application-level correctness.

Cluster queries are bounded to 15 seconds (plus a 2-second forced-termination grace). Database dumps wait at most 30 seconds for initial table locks and run at most 30 minutes; globals dumps run at most 5 minutes, each with a 10-second forced-termination grace. Timeouts return failure and retain previous archives. Choose a manual maintenance window for databases that exceed these limits.

Dump/restore commands put `--cluster 14/apps` first so Debian's client wrapper selects PostgreSQL 14 even when newer clients are installed. Connections explicitly use the apps socket/port; `14/main` is never a fallback.

## Installation and manual use

Run the installer manually, then install an executable boot hook to recreate the helper and cron after reboot or firmware upgrades:

```bash
scp scripts/09-postgresql-ssd-backup.sh root@<gateway-ip>:/data/09-postgresql-ssd-backup.sh
ssh root@<gateway-ip> 'bash /data/09-postgresql-ssd-backup.sh'
ssh root@<gateway-ip> 'install -o root -g root -m 0700 /data/09-postgresql-ssd-backup.sh /data/on_boot.d/09-postgresql-ssd-backup.sh'

# Subsequent manual runs:
/data/unifi-pg-ssd/backup.sh
/data/unifi-pg-ssd/backup.sh --emmc
# Validate the current target and both existing archives without dumping:
/data/unifi-pg-ssd/backup.sh --check
```

Check exit status and logs; installed cron is not evidence of a successful backup. Preflight validates the current cluster and authority even when archives already exist, before replacing the helper/cron. An initial dump failure returns nonzero even though the helper/cron have been installed. Re-running the installer retries missing/invalid archives. `--check` returns 0 for a valid target and archive pair, 2 for missing/invalid archives, and 1 for target/authority/lock failures, with explicit logs. Read each archive's `completed-at` to determine its recovery point; the weekly archive can be up to seven days old if every job succeeds.

## Off-device protection and restore

Copy a newly completed archive to a protected **off-device** location and download a Console backup. SSD-local archives do not protect against SSD failure; eMMC archives do not protect against gateway loss. These are logical backups, **not** automatically loaded boot fallbacks.

Extract the off-device copy into a private directory, run `sha256sum -c SHA256SUMS`, and verify a restore into an isolated compatible PostgreSQL instance with the required roles/owners. Do not post archives/globals in issues, or blindly replay globals over existing roles. Keep off-device generations separately.

See [offload backup/restore instructions](postgresql-ssd-offload.md#manual-backup) for the apps user/socket/port and restore target. Installing this companion does not restore or replace database data.

## Reverting

To stop scheduled backups, archive `09` outside `/data/on_boot.d/` and archive the cron outside `/etc/cron.d/`. Merely changing the boot script's executable bit is insufficient. Preserve the helper and all archives; do not remove `/data/unifi-pg-ssd`, which also holds 08's authority marker. Backups can remain enabled after a checked offload revert because they also work on eMMC.
