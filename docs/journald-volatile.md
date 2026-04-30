# journald-volatile

**Script:** [`scripts/10-journald-volatile.sh`](../scripts/10-journald-volatile.sh)
**Compatibility:** All UniFi Cloud Gateway models (UCG-Fiber, UXG-Fiber, UDM, UDM-Pro, etc.)
**Risk level:** Low - easily reversible, no data loss beyond current boot's logs

## Problem

The default logging configuration writes every log line to eMMC flash from two independent sources:

1. **journald**: `Storage=persistent` writes journal to `/var/log/journal/` on eMMC
2. **syslog-ng**: Reads journal and writes its own log files (`/var/log/messages`, `/var/log/auth.log`, `/var/log/daemon.log`, etc.) to the same eMMC partition

This doubles (or more) the eMMC write load from logging. Combined with other eMMC writers (MongoDB, ubios-udapi-server), it contributes to flash garbage collection stalls that can drop packets on CPU-attached ports.

Note: UCG models use **syslog-ng**, not rsyslog. Setting `ForwardToSyslog=no` in journald.conf does not stop syslog-ng from writing - it reads journal files directly. Both sources must be addressed.

## What the Script Does

### Part 1: journald

Changes two settings in `/etc/systemd/journald.conf`:

| Setting | Stock | Changed |
|---|---|---|
| `Storage` | `persistent` | `volatile` |
| `ForwardToSyslog` | `yes` | `no` |

Journal moves to `/run/log/journal/` (tmpfs in RAM). Logs are available during the current boot via `journalctl` but don't survive a reboot.

### Part 2: syslog-ng

Comments out `log{}` routes in `/etc/syslog-ng/conf.d/` that write to local eMMC file destinations. The approach:

1. Finds all `destination` definitions writing to `file("/var/log/...")` on eMMC
2. Excludes destinations writing to `/var/log/ulog/` (tmpfs, not eMMC - see below)
3. Comments out `log{}` lines that reference those eMMC destinations
4. Leaves destination definitions intact (avoids syslog-ng `persist_name` uniqueness collisions)
5. Restarts syslog-ng

**What is preserved (NOT commented out):**
- **Remote syslog forwarding** (`d_udapi_server_remote`) - log lines continue flowing to the console via UDP
- **`/var/log/ulog/` destinations** - this directory is a firmware-default tmpfs mount (64 MB), not on eMMC

### Why `/var/log/ulog/` must be preserved

The IDS/IPS threat alert pipeline flows through syslog-ng:

```
Suricata → ubnt-idsips-daemon → /run/ids_ips_threat_log.sock → syslog-ng → /var/log/ulog/threat.log
```

The `threat_log.conf` syslog-ng config defines a `unix-stream` source on this socket. syslog-ng only opens the socket when there's an active `log{}` route referencing the source. If the log route is commented out, the socket is never opened, `ubnt-idsips-daemon` gets "connection refused" on every alert, and **all IDS/IPS threat detections are silently dropped**.

Since `/var/log/ulog/` is tmpfs (verified via `mount | grep ulog`), writing to it has zero eMMC impact. The script explicitly excludes these destinations from pruning.

Both parts are idempotent - if already configured, the script exits without touching anything.

## Trade-offs

**What you lose:**
- Logs don't survive a reboot or crash
- `journalctl --boot=-1` (previous boot logs) won't work
- No post-crash forensics from persistent logs
- Local syslog files (`/var/log/messages`, `/var/log/auth.log`, etc.) stop being written

**What you keep:**
- All logs during current boot via `journalctl`
- `dmesg` for kernel messages (separate from journald)
- Remote syslog forwarding to the console (UDP to `d_udapi_server_remote`)
- IDS/IPS threat alerts flowing to `/var/log/ulog/threat.log` (tmpfs) and forwarded to console
- UniFi controller logs in `/data/unifi/logs/` (if running on-box) - unaffected
- RAM usage capped at 40MB by the stock `RuntimeMaxUse=40M` setting

**Why it's acceptable for a gateway:**
- If it crashes, you SSH in and check `dmesg`
- Remote syslog to the console captures everything important
- IDS/IPS alerts continue flowing - threat visibility is not affected
- Packet forwarding reliability is more important than log persistence

## Verification

```bash
# Part 1: Check journald is using volatile storage
journalctl --header | grep "File path"
# Should show: /run/log/journal/...

grep "ForwardToSyslog" /etc/systemd/journald.conf
# Should show: ForwardToSyslog=no

# Part 2: Check syslog-ng local routes are commented out
grep "^log " /etc/syslog-ng/conf.d/messages.conf
# Should return nothing (all commented out)

# Check threat_log route is still active (NOT commented out)
grep "^log " /etc/syslog-ng/conf.d/threat_log.conf
# Should show: log { source(s_idsips_threat); destination(d_idsips_threat_file); };

# Check IDS threat socket is listening
ss -xl | grep threat
# Should show: /run/ids_ips_threat_log.sock LISTEN

# Verify /var/log/ulog is tmpfs (not eMMC)
mount | grep ulog
# Should show: tmpfs on /var/log/ulog type tmpfs

# Verify /var/log/messages stopped growing
ls -la /var/log/messages
# Timestamp should be frozen at the time the script ran
```

## Reverting

Both `/etc/systemd/journald.conf` and the syslog-ng conf.d files are on the overlay filesystem, which means edits **persist across reboots** - simply removing the boot script does not revert them. You need to restore stock values manually, or wait for a UniFi OS upgrade which resets the overlay.

```bash
# Part 1: Restore journald stock values
sed -i 's/^Storage=volatile/Storage=persistent/' /etc/systemd/journald.conf
sed -i 's/^ForwardToSyslog=no/ForwardToSyslog=yes/' /etc/systemd/journald.conf
systemctl restart systemd-journald

# Part 2: Uncomment syslog-ng log routes
# The script comments lines with '#log ' - restore them:
for conf in /etc/syslog-ng/conf.d/*.conf; do
    sed -i 's/^#log /log /' "$conf"
done
systemctl restart syslog-ng

# Remove the boot script so it doesn't re-apply on next boot
rm /data/on_boot.d/10-journald-volatile.sh
```

## Impact

Before: ~10-15 eMMC writes/minute from logging alone (journald + syslog-ng combined)
After: 0 eMMC writes/minute from logging. Remote syslog and IDS threat alerts unaffected.
