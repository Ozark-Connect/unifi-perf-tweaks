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

## Network 11 (PostgreSQL) Write Inventory

Measured on a fleet UCG-Fiber: UniFi OS 6.0.10, UniFi Network 11 in PostgreSQL mode, [PostgreSQL SSD offload](postgresql-ssd-offload.md) and [journald volatile](journald-volatile.md) active. Windows were 5 to 10 minutes, so treat the rates as a snapshot, not a daily average.

### Where the eMMC writes go

Rates come from `/sys/fs/ext4/<partition>/session_write_kbytes`. This counter includes journal and metadata blocks.

| Partition | Mount | Rate | Per day |
|---|---|---|---|
| `mmcblk0p6` | `/` overlay upper (holds `/data`) | ~20 KiB/s | ~1.7 GiB |
| `mmcblk0p4` | `/var/log` | ~5.5 KiB/s | ~0.45 GiB |
| `mmcblk0p5` | `/persistent` | 0 | 0 |

### PostgreSQL clusters

The gateway runs three PostgreSQL 14 clusters. The offload moves only `apps`, and that is the only one with measurable write load.

| Cluster | Port | Data dir | WAL in 5 min | On eMMC? |
|---|---|---|---|---|
| `apps` (UniFi Network) | 5434 | `/data/postgresql/14/apps/data` | 1.76 MiB (~0.5 GiB/day before checkpoint writes) | No, offloaded |
| `main` (UniFi OS core, `ulp-go`) | 5432 | `/data/postgresql/14/main/data` | 0 | Yes |
| `protect` | 5433 | `/srv/postgresql/14/protect/data` | Not measured | Not checked |

`main` shows millions of commits in `pg_stat_database` (`ulp-go` alone has 2.3M). These are read transactions: the WAL position did not move. Both measured clusters run `synchronous_commit=off`. The `protect` cluster held no data files open for write on a gateway with no recording load. A site that records cameras can differ.

### The remaining load is log write amplification

Log files on the overlay grew by only ~56 KiB/min across all of them. The partition took ~1.2 MiB/min. The difference is amplification:

- `/proc/fs/jbd2/mmcblk0p6-8/info` showed 94% of journal commits since boot as *requested* commits, which means a process called `fsync`/`fdatasync`. In a 60 s sample, all 12 commits were requested, so about one every 5 s.
- Each commit logs ~12 blocks (48 KiB) to the journal.
- With `data=ordered`, each commit also writes out the dirty tail block of every file appended since the previous commit. About 20 log files are appended continuously, so most commits rewrite most of those tail blocks.

The fsync caller is not identified. This kernel has no `/proc/<pid>/io` (no task I/O accounting), no ftrace, and no `strace`. The most likely candidate is `udapi-server` rewriting `/data/udapi-config/mdns.cache` in place every ~3 s.

`ulp-go-app` opens `/data/ulp-go/log/std.log` and `std.err.log` with `O_SYNC` (fd flags `04412001`), and `unifi-identity-update` does the same in `/var/log/unifi_package-identity-update/`. Each append forces a journal commit. `std.log` was written only every 2 minutes during the sample, so it is not the 5 s driver.

### Active writers by location

From a 1 s poll of changed files over 60 s and `lsof` open-for-write handles:

| Location | Writers |
|---|---|
| `/data/unifi/logs/` | `tasks.log`, `access.log`, `gc.log`, `server.log`, `stats.log`, `matter-controller/*.log` |
| `/data/unifi-core/logs/` | `nginx-access.log`, `health.log`, `health.pressure.log`, `cloud.devices.log` and ~40 more open for append |
| `/data/ulp-go/log/` | `all.log`, `identity.log`, `vpn.log`, `std.log`, `metrics/metrics-<date>.log` and ~30 more open for append |
| `/var/cache/nginx/` (overlay) | `proxy_temp/*` buffered responses, `uos_auth/*` cache entries rewritten every few seconds |
| `/data/udapi-config/` | `mdns.cache` every ~3 s |
| `/var/lib/rabbitmq/`, `/var/lib/fluent-bit-audit/` | Open for write, no change seen in the 60 s poll |
| `/var/log/` | `query-dnscrypt-proxy-doh-0.log` (largest on the partition), `analytic_report.log`, `mem_trend/*.csv`, `sysstat/sa*` |

### What would reduce it

Not implemented. Candidates in order of expected effect:

1. **Move the three application log directories off the eMMC** (`/data/unifi/logs`, `/data/unifi-core/logs`, `/data/ulp-go/log`), with a bind mount from the SSD as `08` does for PostgreSQL. This removes the files that the fsync-driven commits flush. The services hold these files open, so the bind must be in place before they start, or the services must restart after it.
2. **Put `/var/cache/nginx/proxy_temp` and `uos_auth` on tmpfs.** Both hold disposable data.
3. **Find the fsync caller.** If it is `mdns.cache`, a bind mount for that one file removes the commit cadence that drives the amplification.

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
