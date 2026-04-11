# journald-volatile

**Script:** [`scripts/10-journald-volatile.sh`](../scripts/10-journald-volatile.sh)
**Compatibility:** All UniFi Cloud Gateway models
**Risk level:** Low - easily reversible, no data loss beyond current boot's logs

## Problem

The default journald configuration writes every log line to eMMC flash:

- `Storage=persistent` writes journal to `/var/log/journal/` on eMMC
- `ForwardToSyslog=yes` duplicates every log line to `/var/log/messages` on the same eMMC partition

This doubles the eMMC write load from logging. Combined with other eMMC writers (MongoDB, ubios-udapi-server), it contributes to flash garbage collection stalls that can drop packets on CPU-attached ports.

## What the Script Does

Changes two settings in `/etc/systemd/journald.conf`:

| Setting | Stock | Changed |
|---|---|---|
| `Storage` | `persistent` | `volatile` |
| `ForwardToSyslog` | `yes` | `no` |

Journal moves to `/run/log/journal/` (tmpfs in RAM). Logs are available during the current boot via `journalctl` but don't survive a reboot.

The script is idempotent - if already configured, it exits without touching anything.

## Trade-offs

**What you lose:**
- Logs don't survive a reboot or crash
- `journalctl --boot=-1` (previous boot logs) won't work
- No post-crash forensics from persistent logs

**What you keep:**
- All logs during current boot via `journalctl`
- `dmesg` for kernel messages (separate from journald)
- UniFi controller logs in `/data/unifi/logs/` (server.log, mongod.log) - unaffected
- RAM usage capped at 40MB by the stock `RuntimeMaxUse=40M` setting

**Why it's acceptable for a gateway:**
- If it crashes, you SSH in and check `dmesg`
- The UniFi controller has its own logging that's unaffected
- Packet forwarding reliability is more important than log persistence

## Verification

```bash
# Check journald is using volatile storage
journalctl --header | grep "File path"
# Should show: /run/log/journal/...

# Check no syslog forwarding
grep "ForwardToSyslog" /etc/systemd/journald.conf
# Should show: ForwardToSyslog=no

# Verify /var/log/messages stopped growing
ls -la /var/log/messages
# Timestamp should be frozen at the time the script ran
```

## Reverting

`/etc/systemd/journald.conf` is on the overlay filesystem, which means the script's edits **persist across reboots** - simply removing the boot script does not revert them. You need to restore stock values manually, or wait for a UniFi OS upgrade which resets the overlay.

```bash
# Restore stock values
sed -i 's/^Storage=volatile/Storage=persistent/' /etc/systemd/journald.conf
sed -i 's/^ForwardToSyslog=no/ForwardToSyslog=yes/' /etc/systemd/journald.conf
systemctl restart systemd-journald

# Also remove the boot script so it doesn't re-apply on next boot
rm /data/on_boot.d/10-journald-volatile.sh
```

## Impact

Before: ~10-15 eMMC writes/minute from logging alone
After: 0 eMMC writes/minute from logging
