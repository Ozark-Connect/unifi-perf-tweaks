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

Comparison at 2.7 hours uptime (stock vs. `-Xms384M`):

| Metric | Stock (`-Xms128M`) | Tuned (`-Xms384M`) | Improvement |
|---|---|---|---|
| Total GC events | 1,769 | 343 | **5.2x fewer** |
| Full GCs | 132 | 32 | **4.1x fewer** |
| Full GCs/hour | 48.4 | 11.7 | **4.1x fewer** |
| Full GC interval | avg 73s | avg 304s | **4.2x longer** |
| Double-taps (<3s gap) | 3 | 0 | **Eliminated** |
| CPU time in GC | 0.646% | 0.213% | **3x less** |

The key improvement is **interval between Full GCs** - from every ~1-2 minutes to every ~5 minutes. The individual pause duration doesn't change (it's proportional to live data size), but they happen far less often.

Hourly trend (tuned config):

| Hour | Full GCs | Total GCs | Avg Full GC interval |
|---|---|---|---|
| 0 | 10 | 56 | 375s |
| 1 | 11 | 81 | 323s |
| 2 | 11 | 206 | 220s |

Intervals degrade from 375s to 220s by hour 2 as the controller warms up and the live data set grows. Still 3x better than stock (73s avg). At 23+ hours, stock settings degrade to Full GC every 18-26s. 24-hour soak results for `-Xms384M` pending.

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
