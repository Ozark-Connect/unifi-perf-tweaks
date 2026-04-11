# Emergency Recovery — MongoDB SSD Offload

If `06-mongodb-ssd-offload.sh` / `07-mongodb-ssd-backup.sh` misbehaves and you need to get back to stock eMMC behavior, this is the rollback. It's safe to paste on a running gateway — everything is idempotent and tolerates steps that were already done.

You need SSH to the gateway. These scripts never touch `sshd`, routing, or network config, so SSH almost always survives any failure mode.

## Rollback

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
systemctl is-active unifi
EOF
```

After that:

- Boot scripts removed, so the bind mount won't re-establish on the next reboot.
- Backup cron and helper removed.
- Controller restarted, running on eMMC.
- **The SSD copy is left intact as a safety net.** On UniFi OS 5.0.x this lives at `/volume1/unifi-db/` and `/volume1/unifi-db-backup/`; on UniFi OS 5.1.7+ EA it lives at `/volume/<uuid>/unifi-db/` and `/volume/<uuid>/unifi-db-backup/` (the mount path changes between versions — run `findmnt /dev/md3` to find it on your gateway). If the eMMC copy turns out to be stale or broken, those directories are your fallback. Once the gateway is confirmed healthy on eMMC, you can `rm -rf` them to reclaim the space.

## When this isn't enough

Physical access (reset button) is required only if SSH itself is unreachable — kernel panic, root filesystem corruption, hardware failure, or lost routing. None of those can be caused by these scripts, so in practice if SSH worked before you deployed, it works now.
