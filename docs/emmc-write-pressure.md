# eMMC Write Pressure and Packet Loss on UniFi Cloud Gateways

## The Problem

UniFi Cloud Gateways use eMMC flash for their primary storage. On models with CPU-attached network ports (UCG-Fiber's SFP+ ports, for example), eMMC write pressure causes packet loss.

The mechanism:
1. Heavy writes to eMMC trigger the flash controller's garbage collection (GC)
2. eMMC GC stalls all I/O on the flash device for extended periods
3. `ubios-udapi-server` (which runs at nice -15) gets frozen waiting on eMMC I/O
4. Packets arriving on CPU-attached ports are dropped during the stall

This is not eMMC wear - the flash cells are healthy. It's inherent to how eMMC flash controllers manage write amplification under sustained write pressure.

## Major Write Sources

Through profiling with `fatrace`, `iostat`, and `mongod` slow query logs, we identified the following eMMC write sources on a production UCG-Fiber:

### MongoDB Bulk Deletes (Most Impactful)

The UniFi controller periodically purges traffic flow audit records from `ace_audit.traffic_flow`:
- ~15,000 documents deleted every 2-3 hours
- Each delete removes 45,000+ index keys with 118 write lock acquisitions
- Single operation takes 630-1,031ms of sustained eMMC writes
- **Triggers 30+ minutes of eMMC GC afterward**, causing cyclical packet loss

Profiling showed bulk deletes preceded every 30-minute packet loss window, correlated to the second.

**Fix:** [MongoDB SSD Offload](mongodb-ssd-offload.md) - bind-mount MongoDB data directory from NVMe SSD.

### journald + syslog (Second Most Impactful)

Default configuration doubles every log line to eMMC:
- `Storage=persistent` writes journal to `/var/log/journal/`
- `ForwardToSyslog=yes` copies every line to `/var/log/messages`
- Combined: ~10-15 eMMC writes/minute from logging alone

**Fix:** [journald volatile](journald-volatile.md) - switch to RAM-only journal, disable syslog forwarding. Reduces logging eMMC writes to zero.

### Other Sources (Resolved Separately)

These were additional eMMC write sources found during investigation. They're documented here for completeness - if you're experiencing packet loss, check whether any apply to your setup:

| Source | Impact | Fix |
|---|---|---|
| Third-party fan control scripts | Constant PWM writes + logging | Use PID setpoint tuning instead (no background process) |
| `ubnt-dpkg-daemon` version loop | Repeated writes checking package versions | Fix the version mismatch in `/persistent/dpkg/` |
| Suricata logs | ~1.3MB/hr when IPS is on | Offload to SSD or reduce log verbosity |

## How to Check Your eMMC Write Pressure

```bash
# Watch real-time file writes on eMMC
fatrace -f W /dev/mmcblk0p4

# Check I/O stats
iostat -x 5 /dev/mmcblk0

# Check MongoDB slow operations
tail -f /data/unifi/logs/mongod.log | grep "ms$"
```

## eMMC Health Check

```bash
# Check eMMC life estimate
cat /sys/class/mmc_host/mmc0/mmc0:0001/life_time
# Format: 0x0A 0x0B - values 01-0A (10% increments), 0x01=0-10%, 0x0A=90-100%

cat /sys/class/mmc_host/mmc0/mmc0:0001/pre_eol_info
# 0x01=normal, 0x02=warning, 0x03=urgent
```

## The Fix Stack

For maximum impact, deploy in this order:

1. **journald volatile** (biggest bang for least risk) - eliminates ~60-70% of eMMC writes
2. **MongoDB SSD offload** (eliminates the root cause) - moves all MongoDB I/O off eMMC
3. **JVM heap tuning** (complementary) - reduces GC pauses that compound the problem

Together, these reduce eMMC write pressure to near-zero, leaving only occasional `ubios-udapi-server` state writes.
