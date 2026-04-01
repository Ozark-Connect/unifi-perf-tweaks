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

> **Status: Testing in progress (2026-04-01).** Early results show improvement but the advantage narrows as the controller warms up. 24-hour soak test pending before recommending deployment.

### Early results (first 2 hours)

Comparison at 2.7 hours uptime (stock vs. `-Xms384M`):

| Metric | Stock (`-Xms128M`) | Tuned (`-Xms384M`) | Improvement |
|---|---|---|---|
| Total GC events | 1,769 | 343 | **5.2x fewer** |
| Full GCs | 132 | 32 | **4.1x fewer** |
| Full GCs/hour | 48.4 | 11.7 | **4.1x fewer** |
| Full GC interval | avg 73s | avg 304s | **4.2x longer** |
| Double-taps (<3s gap) | 3 | 0 | **Eliminated** |
| CPU time in GC | 0.646% | 0.213% | **3x less** |

### Sustained results (4.6 hours)

The advantage narrows as the controller warms up and live data grows into the headroom:

| Metric | Stock (`-Xms128M`) | Tuned (`-Xms384M`) | Improvement |
|---|---|---|---|
| Total GC events | 2,411 | 1,762 | **1.4x fewer** |
| Full GCs | 198 | 105 | **1.9x fewer** |
| Full GCs/hour | 43.1 | 22.8 | **1.9x fewer** |
| Full GC interval | avg 83s | avg 157s | **1.9x longer** |
| Double-taps (<3s gap) | 7 | 0 | **Eliminated** |
| CPU time in GC | 0.580% | 0.445% | **1.3x less** |

### Hourly trend

| Hour | Stock Full GCs | Stock Interval | Tuned Full GCs | Tuned Interval | Ratio |
|---|---|---|---|---|---|
| 0 | 25 | 144s | 10 | 375s | 2.6x |
| 1 | 71 | 51s | 11 | 323s | 6.4x |
| 2 | 48 | 76s | 18 | 198s | 2.6x |
| 3 | 32 | 111s | 45 | 79s | 0.7x |
| 4 | 22 | 94s | 21 | 102s | 1.1x |

The improvement is strongest in the first 2 hours (~3-6x) while the controller is warming up. By hours 3-4, as live data grows and consumes the extra headroom, the ratio converges to ~1-2x. **Double-taps remain eliminated at all time points** - this is the most consistent benefit.

### Memory impact

| Resource | Stock | Tuned | Delta |
|---|---|---|---|
| JVM RSS | ~300-400MB | 427MB | +43MB |
| System available | ~1,050MB | 1,112MB | +62MB |
| Swap used | ~250MB | 251MB | ~same |

No memory pressure from the higher Xms. The JVM holds a slightly larger heap but isn't consuming proportionally more physical memory.

### Assessment

The `-Xms384M` fix provides a clear improvement in the first 2 hours and eliminates double-tap Full GCs entirely. The sustained improvement (hours 3+) narrows to ~2x as the controller warms up. A higher `-Xms` (512M) may maintain the 3x ratio longer, but needs testing.

**This script is not yet recommended for general deployment.** 24-hour soak test results are needed to determine if the improvement holds long-term or if a different `-Xms` value is optimal. The eMMC and journald scripts provide much larger, proven improvements - deploy those first.

## Verification

```bash
# Check current JVM settings
grep "^UNIFI_NATIVE" /etc/default/unifi

# Monitor GC activity (requires PrintGC to be enabled - it is by default)
journalctl -u unifi -f | grep -i "gc"

# Check controller process for actual flags
ps aux | grep unifi | grep -oP '\-Xm[sx]\S+'
```

## Reverting

Remove the script from `/data/on_boot.d/` and reboot. The overlay resets `/etc/default/unifi` to stock on UniFi OS upgrade, or you can manually restore:

```bash
# Restore stock settings
sed -i 's/-Xms384M/-Xms128M/' /etc/default/unifi
sed -i 's/-Xmx768M/-Xmx640M/' /etc/default/unifi
systemctl restart unifi
```
