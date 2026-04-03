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

### Why Nothing Prevents Heap Shrinking (except locking)

The SubstrateVM Serial GC uses an **Adaptive2 collection policy** with `MIN_HEAP_FREE_RATIO = 0` hardcoded — there is no configurable floor on free space. After each Full GC, the adaptive policy shrinks the committed heap down to just above live data, regardless of what flags you set.

This was confirmed by reading the [GraalVM SubstrateVM source code](https://github.com/oracle/graal/tree/master/substratevm/src/com.oracle.svm.core.genscavenge/src/com/oracle/svm/core/genscavenge) (`HeapChunkProvider.java`, `AdaptiveCollectionPolicy2.java`, `AbstractCollectionPolicy.java`).

### What Doesn't Work

| Flag | Why |
|---|---|
| `-Xms` (when != `-Xmx`) | Only sets initial committed size — adaptive policy shrinks below it in ~50 minutes |
| `-XX:MinHeapSize` | Only constrains initial generation sizes — not checked during shrinking |
| `-XX:MaxHeapFree=N` | **Upper bound (cap)**, not a floor — means "retain at most N free bytes." Can only reduce retention, never increase it. |
| `-XX:MaxHeapFreeRatio=*` | HotSpot flag, not recognized by SubstrateVM |
| Switching to G1GC | Requires Enterprise Edition + native image rebuild |

> **Note on MaxHeapFree:** Ubiquiti's service file sets `MaxHeapFree=0` in `UNIFI_NATIVE_OVERRIDE_OPTS`, meaning "automatic per GC policy." This is actually a real SubstrateVM flag (not Android ART as we initially believed), but since it's an upper bound cap, setting it to any value only limits how much free space the GC retains — it cannot prevent shrinking. Community tuning guides that increase MaxHeapFree are ineffective.
>
> Additionally, `UNIFI_NATIVE_OVERRIDE_OPTS` is appended after `UNIFI_NATIVE_OPTS` on the command line, and **last flag wins**. Any MaxHeapFree value set in NATIVE_OPTS is clobbered by the service file's `MaxHeapFree=0`. The boot script overrides OVERRIDE_OPTS to fix this, but the point is moot since MaxHeapFree doesn't prevent shrinking regardless.

## What the Script Does

1. Detects whether Suricata/IPS is active
2. **Locks the heap** — sets `-Xms` equal to `-Xmx` in `/etc/default/unifi`
3. Strips ineffective flags (`MaxHeapFree`, `MinHeapSize`) from NATIVE_OPTS
4. Overrides `UNIFI_NATIVE_OVERRIDE_OPTS` to remove the service file's stock flags (prevents flag clobbering)
5. Adds `-XX:+ExitOnOutOfMemoryError` (a flag GraalVM actually recognizes)

### Heap Sizes

| IPS Status | Heap (locked) | Rationale |
|---|---|---|
| **Off** | 768M | ~638MB headroom above ~130MB live data → 400-500s Full GC intervals |
| **On** | 640M | Matches Ubiquiti's stock Xmx, known to fit alongside Suricata (~778MB) |

These are configurable at the top of the script.

### Settings Persistence

- Stored in `/etc/default/unifi` (overlay filesystem)
- **Survives UniFi Network upgrades** (e.g., 10.2.104 -> 10.2.105) -- confirmed
- **Does NOT survive UniFi OS upgrades** - the boot script reapplies on next boot
- Does NOT restart the controller - applies on next natural restart

## Profiling Results

> **Status: Testing (2026-04-02).** Locked heap (`-Xms` == `-Xmx`) confirmed as the only effective configuration. 85-minute profiling shows 4x fewer Full GCs and 10x longer intervals vs all unlocked configs. 24-hour soak in progress.

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

### Why unlocked heaps don't work

`-Xms` only sets the **initial** committed heap size. The Adaptive2 collection policy ignores it when shrinking — within ~50 minutes the heap compresses back down to near live data size (~145MB), regardless of the Xms value.

Every unlocked configuration showed the same pattern:

| Config | Heap at 10min | Heap at 50min | Result |
|---|---|---|---|
| `-Xms384M -Xmx768M` | 335M | 165M | Compressed — 72.9/hr Full GCs at 25hr |
| `-Xms512M -Xmx768M` | 335M | 155M | Compressed — identical degradation |
| `-Xms512M -Xmx768M -XX:MaxHeapFree=384M -XX:MinHeapSize=512M` | 343M | 155M | Compressed — MaxHeapFree/MinHeapSize had zero effect |

### The fix: `-Xms` == `-Xmx` (locked heap)

The only way to prevent the Adaptive2 policy from shrinking is to lock the heap: set `-Xms` equal to `-Xmx`. With no room to shrink, the GC retains all free space between collections.

#### Locked heap results (`-Xms768M -Xmx768M`)

At 85 minutes (the point where all unlocked configs had fully degraded):

| Metric | Unlocked (best of 3 configs) | **Locked** |
|---|---|---|
| Full GCs/hr | 26-44 | **10.6** |
| Full GC interval | 28-79s (compressing) | **345-525s (stable)** |
| Double-taps | 0-170 | **0** |
| Heap before GC | 155-195M (compressed) | **329-338M (rock solid)** |

The heap stayed at 329-338M before every Full GC — no compression. Live data stable at 112-119M, giving ~638M headroom that allocations fill over 400-500 seconds before the next Full GC.

### Memory impact

| Resource | Stock | Locked 768M |
|---|---|---|
| JVM committed | ~150-200MB | 768MB |
| System available | ~1,050MB | ~830MB |

The locked heap commits 768MB from startup. On a UCG-Fiber with 2.9GB total RAM, this leaves ~830MB available — comfortable with no Suricata. With Suricata, the script uses 640M (Ubiquiti's stock Xmx) which is known to fit.

### Packet loss impact

**With MongoDB on SSD:** Zero packet loss despite ongoing Full GCs. The eMMC write pressure from MongoDB was the primary cause of packet drops, not JVM GC alone. With MongoDB on SSD, GC pauses (150-350ms) can occasionally drop a single ping but don't cause sustained loss.

**Without MongoDB on SSD:** JVM Full GC pauses compound with eMMC garbage collection to cause real packet loss. If you can't move MongoDB to SSD, JVM heap tuning becomes more important.

### Assessment

The locked heap configuration (`-Xms` == `-Xmx`) provides a clear, stable improvement:
- **4x fewer Full GCs** than any unlocked configuration at steady state
- **10x longer intervals** (400-500s vs 30-70s)
- **Zero double-taps** — eliminates the rapid-fire GC storms that cause packet loss blips
- **No degradation over time** — the heap can't compress because there's nowhere to shrink

24-hour soak test is in progress. The eMMC and journald scripts still provide the largest proven improvements — deploy those first.

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
sed -i 's/-Xms768M/-Xms128M/' /etc/default/unifi
sed -i 's/-Xmx768M/-Xmx640M/' /etc/default/unifi
systemctl restart unifi
```
