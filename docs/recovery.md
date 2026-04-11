# Emergency Recovery - MongoDB SSD Offload

If `06-mongodb-ssd-offload.sh` / `07-mongodb-ssd-backup.sh` misbehaves and you need to get back to stock eMMC behavior, pick the right recovery path below. All three require SSH access to the gateway - which almost always survives any failure mode these scripts can cause, because they don't touch `sshd`, routing, or network config.

## Which path should I use?

```
┌─ Did you JUST try to install 06 for the first time (within the last
│  few minutes) and it's either failing now or you changed your mind?
│
│  ─→ Yes → Path D: First-run rollback
│           Simplest path. The eMMC data is still current because the
│           install is too recent for eMMC and SSD to have diverged.
│
│  ─→ No  → Is the bind-mounted SSD data still readable and current?
│           (i.e., the controller has been running off the SSD for a
│            while, and now you want to stop using the SSD offload,
│            or the SSD hardware itself is healthy)
│
│           ─→ Yes → Path A: Live-migrate back to eMMC
│                    Controller ends up on eMMC with your current,
│                    up-to-date data.
│
│           ─→ No  → Is a backup from 07-mongodb-ssd-backup.sh available?
│                    (check /volume1/unifi-db-backup/ and
│                     /data/unifi/data/db-backup/)
│
│                    ─→ Yes → Path B: Restore from backup via mongorestore
│                             Controller ends up on eMMC with data up to
│                             24h old (SSD daily) or 7d old (eMMC weekly).
│
│                    ─→ No  → Path C: Nuclear fallback on the pre-deploy
│                             snapshot. STALE - potentially weeks or
│                             months old. Only use if you're about to
│                             restore from a UniFi Console UI backup
│                             afterward, or you're OK losing everything
│                             after the initial offload date.
```

> **Every path below is idempotent and safe to re-run.** If you start down one path and decide to switch, just run the next path's snippet - each one starts by stopping the stack cleanly.

---

## Path D - First-run install rollback

**Use when:** You just deployed `06-mongodb-ssd-offload.sh` for the first time (minutes ago, not days ago), and either:
- The live-run failed mid-way and left the gateway in a partial state
- The live-run completed but unifi won't start or is behaving badly
- You successfully deployed it but changed your mind and want to back out immediately

**Why this is simpler than Path A:** The `cp -a` from `/data/unifi/data/db` to `/volume1/unifi-db/` just happened. No writes have landed on the SSD since, which means the eMMC copy under the bind mount is **byte-identical** to the SSD copy - unmounting exposes *current* data, not the stale pre-deploy snapshot that Path C's warning is about. You don't need to copy anything back to eMMC; the data is already there.

**Pre-conditions:**
- `06` ran within the last few minutes. If it's been hours or days, use Path A instead - writes have almost certainly landed on the SSD that aren't on eMMC.
- You haven't deployed `07-mongodb-ssd-backup.sh` *and* had it successfully run a backup yet. (If you have, it's fine - just also run `rm -rf /volume1/unifi-db-backup /data/unifi/data/db-backup` afterward to clean up the unused artifacts.)

**Controller outage:** 10–30 seconds.

```bash
ssh root@<gateway-ip> bash -s << 'EOF'
set +e

# 1. Stop the whole stack cleanly
systemctl stop unifi-mongodb.service
if pgrep -x mongod >/dev/null; then
    echo "FAIL: mongod still running after systemctl stop; aborting"
    exit 1
fi

# 2. Unmount the bind mount if it's active. On a failed first-run this
#    may or may not be up depending on where the script aborted.
umount /data/unifi/data/db 2>/dev/null

# 3. Remove boot scripts and helpers so nothing re-establishes the
#    offload on next boot
rm -f /data/on_boot.d/06-mongodb-ssd-offload.sh
rm -f /data/on_boot.d/07-mongodb-ssd-backup.sh
rm -f /etc/cron.d/mongodb-ssd-backup
rm -rf /data/unifi-db-ssd

# 4. Clean up the SSD copy that 06 just created (safe because eMMC has
#    an identical copy). Uses the same /volume1 and /volume/<uuid>/
#    detection as the script itself.
SSD_MOUNT=""
if mountpoint -q /volume1 2>/dev/null; then
    SSD_MOUNT=/volume1
else
    for d in /volume/*/; do
        [ -d "$d" ] && mountpoint -q "${d%/}" 2>/dev/null && { SSD_MOUNT="${d%/}"; break; }
    done
fi
if [ -n "$SSD_MOUNT" ]; then
    rm -rf "$SSD_MOUNT/unifi-db"
    rm -rf "$SSD_MOUNT/unifi-db-backup"
fi
rm -rf /data/unifi/data/db-backup

# 5. Start unifi. systemd pulls unifi-mongodb as a dep and mongod opens
#    the eMMC copy of the data - which is current, because no writes
#    have happened since the cp.
systemctl start unifi

# 6. Verify
findmnt /data/unifi/data/db && echo "WARN: something is still mounted at /data/unifi/data/db"
systemctl is-active unifi unifi-mongodb
EOF
```

**Result:** Gateway is back to exactly the state it was in before you ran `06`. No stale data, no orphaned SSD directories, no boot scripts queued for next reboot. Tidy.

**If you want to try the install again later:** fine - just re-deploy `06` normally. The SSD directories are gone, so the next run will hit the first-run migration path cleanly.

---

## Path A - Live-migrate back to eMMC (happy path)

**Use when:** The SSD and the bind-mounted data are both healthy. You're removing the offload for operational reasons (testing, migrating, debugging), not because anything is broken. This is the right path ~95% of the time.

**Pre-conditions:**
- `systemctl is-active unifi-mongodb` → `active`
- `findmnt /data/unifi/data/db` shows `/dev/md3[/unifi-db]` (i.e. the bind mount is still up)
- eMMC has at least 2× the DB size free (`df -h /data`)

**Controller outage:** ~60–90 seconds depending on DB size.

```bash
ssh root@<gateway-ip> bash -s << 'EOF'
set +e

# 1. Stop the whole stack cleanly. systemctl stop of unifi-mongodb runs
#    mongod --shutdown and cascades to stop unifi via reverse Requires.
systemctl stop unifi-mongodb.service

# 2. Verify mongod is really gone before touching the filesystem
if pgrep -x mongod >/dev/null; then
    echo "FAIL: mongod still running after systemctl stop; aborting"
    exit 1
fi

# 3. Find the SSD mount path (handles both 5.0.x /volume1 and 5.1.7+
#    /volume/<uuid>/) and verify the live data directory is there
SSD_MOUNT=""
if mountpoint -q /volume1 2>/dev/null; then
    SSD_MOUNT=/volume1
else
    for d in /volume/*/; do
        [ -d "$d" ] && mountpoint -q "${d%/}" 2>/dev/null && { SSD_MOUNT="${d%/}"; break; }
    done
fi
if [ -z "$SSD_MOUNT" ] || [ ! -f "$SSD_MOUNT/unifi-db/WiredTiger" ]; then
    echo "FAIL: cannot find live SSD data at \$SSD_MOUNT/unifi-db"
    echo "      → use Path B (restore from backup) or Path C (nuclear)"
    exit 1
fi
echo "Live SSD data at: $SSD_MOUNT/unifi-db"

# 4. Check eMMC has enough room for the DB (2x for safety margin)
SSD_SIZE_KB=$(du -sk "$SSD_MOUNT/unifi-db" | awk '{print $1}')
EMMC_FREE_KB=$(df -k /data | tail -1 | awk '{print $4}')
if [ "$EMMC_FREE_KB" -lt "$((SSD_SIZE_KB * 2))" ]; then
    echo "FAIL: eMMC free=${EMMC_FREE_KB}KB but need ~$((SSD_SIZE_KB * 2))KB (2x DB size)"
    echo "      → free up space or use Path B (mongorestore streams and uses less)"
    exit 1
fi

# 5. Unmount the bind mount. This exposes whatever eMMC data was at
#    /data/unifi/data/db BEFORE the first bind mount - usually stale.
umount /data/unifi/data/db

# 6. Wipe the stale eMMC copy so we can drop in the current SSD data
rm -rf /data/unifi/data/db/* /data/unifi/data/db/.[!.]*

# 7. Copy the LIVE SSD data back to the eMMC path. The trailing `/.` is
#    intentional - copies contents, including dot-files, into the
#    existing target directory.
cp -a "$SSD_MOUNT/unifi-db/." /data/unifi/data/db/
chown -R unifi:unifi /data/unifi/data/db

# 8. Remove the boot scripts and all backup helpers so nothing
#    re-establishes the offload on next boot
rm -f /data/on_boot.d/06-mongodb-ssd-offload.sh
rm -f /data/on_boot.d/07-mongodb-ssd-backup.sh
rm -f /etc/cron.d/mongodb-ssd-backup
rm -rf /data/unifi-db-ssd

# 9. Start unifi. systemd pulls in unifi-mongodb as a dependency,
#    and mongod opens the eMMC copy of the data we just wrote.
systemctl start unifi

# 10. Verify the bind mount is gone and services are active
findmnt /data/unifi/data/db && echo "WARN: something is still mounted at /data/unifi/data/db"
systemctl is-active unifi unifi-mongodb
EOF
```

**Result:** eMMC now holds the same data the SSD held at rollback time. `/volume1/unifi-db/` and `/volume1/unifi-db-backup/` (or the `/volume/<uuid>/...` equivalents on 5.1.7+) are left intact as a final safety net - delete them manually after you're sure the gateway is healthy on eMMC.

---

## Path B - Restore from backup via `mongorestore`

**Use when:** The SSD is gone, unreachable, or the bind-mounted data is corrupt. At least one of the backup directories from `07` still has a usable dump in it.

**Pre-conditions:**
- Either `/volume1/unifi-db-backup/` or `/data/unifi/data/db-backup/` is non-empty (or the `/volume/<uuid>/` equivalent)
- eMMC has enough free space for the restored DB (similar to Path A)

**Data age:** Up to 24 hours old (SSD daily backup) or up to 7 days old (eMMC weekly failover). The snippet picks whichever is newest.

**Controller outage:** 2–5 minutes (longer than Path A because mongorestore rewrites every collection).

```bash
ssh root@<gateway-ip> bash -s << 'EOF'
set +e

# 1. Stop the whole stack cleanly
systemctl stop unifi-mongodb.service
if pgrep -x mongod >/dev/null; then
    echo "FAIL: mongod still running after systemctl stop; aborting"
    exit 1
fi

# 2. Find the newest usable backup. Prefer the SSD daily (≤24h old)
#    over the eMMC weekly failover (≤7d old), falling back only if
#    the SSD is unreachable.
BACKUP=""
SSD_MOUNT=""
if mountpoint -q /volume1 2>/dev/null; then
    SSD_MOUNT=/volume1
else
    for d in /volume/*/; do
        [ -d "$d" ] && mountpoint -q "${d%/}" 2>/dev/null && { SSD_MOUNT="${d%/}"; break; }
    done
fi
if [ -n "$SSD_MOUNT" ] && [ -d "$SSD_MOUNT/unifi-db-backup" ] && [ -n "$(ls -A "$SSD_MOUNT/unifi-db-backup" 2>/dev/null)" ]; then
    BACKUP="$SSD_MOUNT/unifi-db-backup"
    echo "Using SSD daily backup: $BACKUP (≤24h old)"
elif [ -d /data/unifi/data/db-backup ] && [ -n "$(ls -A /data/unifi/data/db-backup 2>/dev/null)" ]; then
    BACKUP="/data/unifi/data/db-backup"
    echo "Using eMMC weekly failover: $BACKUP (≤7d old)"
else
    echo "FAIL: no usable backup found in either location"
    echo "      → use Path C (nuclear fallback) or restore from a UniFi Console UI backup"
    exit 1
fi

# 3. Unmount the bind mount (if still up) and wipe the eMMC dir so
#    mongod starts against an empty directory
umount /data/unifi/data/db 2>/dev/null
rm -rf /data/unifi/data/db/* /data/unifi/data/db/.[!.]*
chown unifi:unifi /data/unifi/data/db

# 4. Remove boot scripts and helpers so the offload doesn't re-establish
rm -f /data/on_boot.d/06-mongodb-ssd-offload.sh
rm -f /data/on_boot.d/07-mongodb-ssd-backup.sh
rm -f /etc/cron.d/mongodb-ssd-backup
rm -rf /data/unifi-db-ssd

# 5. Start unifi-mongodb alone on the empty eMMC dir. mongod creates a
#    fresh WiredTiger storage engine. unifi.service stays stopped for now.
systemctl start unifi-mongodb.service
sleep 5
if ! pgrep -x mongod >/dev/null; then
    echo "FAIL: mongod did not start after wipe; check journalctl -u unifi-mongodb"
    exit 1
fi

# 6. Restore the backup into the running mongod. --drop clears each
#    collection before inserting, which is what you want against the
#    blank DB mongod just created.
mongorestore --port 27117 --drop "$BACKUP"
RC=$?
if [ "$RC" -ne 0 ]; then
    echo "FAIL: mongorestore exited $RC - DB is in an uncertain state"
    echo "      → inspect /data/unifi/data/db manually or fall back to Path C"
    exit 1
fi

# 7. Start unifi. unifi-mongodb is already up from step 5, so this just
#    brings up the Java controller against the restored DB.
systemctl start unifi
systemctl is-active unifi unifi-mongodb
EOF
```

**Result:** eMMC now holds a restored copy of the newest available backup. `/volume1/unifi-db/` is left intact if the SSD was still readable - do not delete it until you've confirmed the restored DB is healthy, in case the restore turns out to be incomplete.

---

## Path C - Nuclear fallback (stale pre-deploy snapshot)

> ⚠️ **READ THIS FIRST.** This path recovers the eMMC directory as it was at the moment `06-mongodb-ssd-offload.sh` first ran. On a gateway that's been running the SSD offload for weeks or months, that snapshot is **weeks or months out of date**. You will lose everything that happened since the offload was first deployed. Only use this path if you cannot complete Path A or Path B **and** you plan to restore from a UniFi Console UI backup immediately afterward (or you genuinely accept the data loss).

**Use when:** Both Path A and Path B are impossible - the SSD is gone, the bind mount is broken, and neither backup directory has usable data.

```bash
ssh root@<gateway-ip> bash -s << 'EOF'
set +e
systemctl stop unifi-mongodb.service 2>/dev/null
pgrep -x mongod && pkill -TERM -x mongod
sleep 5
umount /data/unifi/data/db 2>/dev/null
rm -f /data/on_boot.d/06-mongodb-ssd-offload.sh
rm -f /data/on_boot.d/07-mongodb-ssd-backup.sh
rm -f /etc/cron.d/mongodb-ssd-backup
rm -rf /data/unifi-db-ssd
systemctl start unifi
findmnt /data/unifi/data/db || echo "OK: /data/unifi/data/db is no longer a bind mount"
systemctl is-active unifi unifi-mongodb
EOF
```

**Result:** Controller is running on eMMC, but the DB is the pre-deploy snapshot. Log in to the UniFi Console UI immediately, go to Settings → Control Plane → Backups, and either restore from a recent backup file you saved earlier or accept that you're starting over.

---

## When this isn't enough

Physical access (reset button) is required only if SSH itself is unreachable - kernel panic, root filesystem corruption, hardware failure, or lost routing. None of those can be caused by these scripts, so in practice if SSH worked before you deployed, it works now.
