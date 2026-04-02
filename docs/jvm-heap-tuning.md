# jvm-heap-tuning

**Script:** [`scripts/11-jvm-heap-tuning.sh`](../scripts/11-jvm-heap-tuning.sh)
**Compatibility:** All UniFi Cloud Gateway models
**Risk level:** Low - does not restart the controller; settings apply on next restart

## Problem

The UniFi controller is a **GraalVM Native Image** (Liberica NIK, SubstrateVM, Serial GC). The stock JVM configuration ships with a low `-Xms` (minimum heap size), which causes the Serial GC to shrink the heap after each Full GC back to near the live data size (~120MB). This leaves only 30-80MB of headroom for new allocations.

The result:
1. Full GC fires every 30-70 seconds (150-350ms stop-the-world pauses)
2. "Double-tap" patterns where two Full GCs fire within 1 second
3. On models with CPU-attached network ports, each GC pause drops packets

### Why `-XX:MaxHeapFree` Does Nothing

Ubiquiti's service file includes `-XX:MaxHeapFree=0` in `UNIFI_NATIVE_OVERRIDE_OPTS`. This is an **Android ART flag** - GraalVM silently ignores it. All community tuning guides that adjust `MaxHeapFree` have no effect.

The actual lever for GraalVM Serial GC is **`-Xms`** - it sets the committed heap floor so the GC can't shrink the heap back to the live data size.

### What Doesn't Work

| Flag | Why |
|---|---|
| `-XX:MaxHeapFree=*` | Android ART flag, silently ignored by GraalVM |
| `-XX:MaxHeapFreeRatio=*` | HotSpot flag, not recognized by SubstrateVM |
| Switching to G1GC | Requires Enterprise Edition + native image rebuild |

## What the Script Does

1. Detects whether Suricata/IPS is active
2. Sets appropriate `-Xms` and `-Xmx` values in `/etc/default/unifi`
3. Removes dead ART flags (`MaxHeapFree`, `StackSize`) from `UNIFI_NATIVE_OVERRIDE_OPTS`
4. Adds `-XX:+ExitOnOutOfMemoryError` (a flag GraalVM actually recognizes)

### Heap Sizes

| IPS Status | `-Xms` | `-Xmx` | Rationale |
|---|---|---|---|
| **Off** | 384M | 768M | ~250MB headroom above ~120MB live data |
| **On** | 256M | 768M | Suricata uses ~778MB, smaller floor to leave room |

These are configurable at the top of the script.

### Settings Persistence

- Stored in `/etc/default/unifi` (overlay filesystem)
- **Survives UniFi Network upgrades** (e.g., 10.2.104 -> 10.2.105) -- confirmed
- **Does NOT survive UniFi OS upgrades** - the boot script reapplies on next boot
- Does NOT restart the controller - applies on next natural restart

## Profiling Results

> **Status: Testing (2026-04-02).** 28-hour soak test complete. The improvement is real but modest at steady state. Still determining optimal `-Xms` value — 384M may be insufficient as live data grows.

### Early results (first 2.7 hours)

Comparison at 2.7 hours uptime (stock vs. `-Xms384M`):

| Metric | Stock (`-Xms128M`) | Tuned (`-Xms384M`) | Improvement |
|---|---|---|---|
| Full GCs | 132 | 32 | **4.1x fewer** |
| Full GCs/hour | 48.4 | 11.7 | **4.1x fewer** |
| Full GC interval | avg 73s | avg 304s | **4.2x longer** |
| Double-taps (<3s gap) | 3 | 0 | **Eliminated** |
| CPU time in GC | 0.646% | 0.213% | **3x less** |

These early numbers are impressive but **do not hold** — see 28-hour results below.

### 28-Hour Soak Test Results

The controller's live data set grows from ~120MB at startup to ~143-145MB by hour 6, where it stabilizes. This eats into the 384MB floor, reducing effective headroom from ~264MB to ~239MB.

**Overall at 28 hours: 1,978 Full GCs, 70.6/hr avg, 170 double-taps**

| Time of Day (CDT) | Full GCs/hr | Notes |
|---|---|---|
| Wed 09:29 (startup) | 41 | JVM warming up |
| Wed 10:29-11:29 | 66-82 | Live data growing |
| Wed 14:29-15:29 | 113-118 | Afternoon peak (highest sustained) |
| Wed 17:29-18:29 | 34-50 | Evening — best hours, intervals 300-500s |
| Wed 23:29-Thu 00:29 | 41-42 | Overnight low |
| Thu 03:29 | **264** | Spike — possibly controller housekeeping or post-testing GC storm |
| Thu 07:29-08:29 | 35-46 | Overnight recovery |
| Thu 09:29-10:29 | 28 | Morning calm |
| **Thu 10:29-13:29** | **28-52** | **Day 2 settling — significantly better than day 1 at same hours** |

**Key observation: Day 2 is better than day 1 at the same time of day.** The controller settled in overnight:

| Time of Day | Day 1 | Day 2 | Improvement |
|---|---|---|---|
| 09:29-10:29 | 82 | 28 | 2.9x better |
| 10:29-11:29 | 66 | 39 | 1.7x better |
| 11:29-12:29 | 77 | 52 | 1.5x better |
| 12:29-13:29 | 82 | 30 | 2.7x better |

Live data stabilized at 143-145MB (no longer growing). Day-2 rates of 28-52/hr are the real baseline.

### Memory impact

| Resource | Stock | Tuned | Delta |
|---|---|---|---|
| JVM RSS | ~300-400MB | ~337MB | Minimal |
| System available | ~1,050MB | ~920MB | Acceptable |
| Swap used | ~250MB | ~262MB | ~same |

No memory pressure from the higher Xms.

### Packet loss impact

**With MongoDB on SSD:** Zero packet loss despite ongoing Full GCs. The eMMC write pressure from MongoDB was the primary cause of packet drops, not JVM GC alone. GC pauses (150-350ms) can occasionally drop a single ping but don't cause the sustained multi-second stalls that eMMC contention does.

**Without MongoDB on SSD:** JVM Full GC pauses compound with eMMC garbage collection to cause real packet loss. If you can't move MongoDB to SSD, JVM heap tuning becomes more important.

### Assessment

`-Xms384M` provides a meaningful improvement that stabilizes after day 1:
- **Day 2 steady state: 28-52 Full GCs/hr** (vs day 1: 66-118/hr at same hours)
- Double-taps still occur (170 in 28hr) but are less frequent than stock
- Live data plateaus at ~145MB — the 384MB floor gives ~240MB headroom at steady state

**This script is not yet recommended for general deployment.** We're still determining if `-Xms512M` would provide more consistent results. The eMMC and journald scripts provide much larger, proven improvements — deploy those first.

## Verification

```bash
# Check current JVM settings
grep "^UNIFI_NATIVE" /etc/default/unifi

# Check controller process for actual flags
# NOTE: The native image runs as "unifi", not "java" — pidof java won't find it
ps aux | grep "/usr/lib/unifi/lib/unifi" | grep -oP '\-Xm[sx]\S+'

# GC logs go to a file, NOT journalctl
tail -20 /data/unifi/logs/gc.log

# Count Full GCs
grep -c "Full GC" /data/unifi/logs/gc.log

# Watch live GC activity
tail -f /data/unifi/logs/gc.log | grep "Full GC"
```

## Reverting

Remove the script from `/data/on_boot.d/` and reboot. The overlay resets `/etc/default/unifi` to stock on UniFi OS upgrade, or you can manually restore:

```bash
# Restore stock settings
sed -i 's/-Xms384M/-Xms128M/' /etc/default/unifi
sed -i 's/-Xmx768M/-Xmx640M/' /etc/default/unifi
systemctl restart unifi
```
