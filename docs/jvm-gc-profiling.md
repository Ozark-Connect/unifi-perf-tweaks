# JVM Garbage Collection Profiling

## Key Discovery: It's GraalVM, Not Android ART

The UniFi controller is a **GraalVM Native Image** (Liberica NIK 25.0.0, SubstrateVM, Serial GC). This was confirmed via:

```bash
strings /usr/lib/unifi/lib/unifi | grep "com.oracle.svm"
# com.oracle.svm.core.VM=Liberica-NIK-25.0.0-1
# com.oracle.svm.core.VM.Target.Platform=org.graalvm.nativeimage.Platform$LINUX_AARCH64
```

This is significant because **most community tuning guides assume it's Android ART** (based on the `-XX:MaxHeapFree` flag in Ubiquiti's service file). That flag is an ART-specific parameter - GraalVM silently ignores it. All tuning advice that adjusts `MaxHeapFree` has zero effect.

## How SubstrateVM Serial GC Works

Serial GC is the only garbage collector available in GraalVM Community Edition (G1 requires Enterprise Edition and a native image rebuild). It operates with two collection types:

- **Incremental GC:** Collects young generation only. Fast (30-60ms), partial collection.
- **Full GC:** Collects entire heap, compacts memory. Stop-the-world, 150-350ms depending on live data size.
- **"Collect on allocation":** Full GC triggered when an allocation can't be satisfied from free space.

After a Full GC, the Serial GC can shrink the committed heap back toward `-Xms`. This is the root cause of the thrashing problem.

## The Shrink-Grow Cycle

With stock settings (`-Xms128M`):

1. Full GC compacts heap to ~110-120MB (live data)
2. Heap shrinks toward 128MB floor - only 8-30MB headroom
3. UniFi controller allocates heavily (Netty, JSON, MongoDB queries)
4. 30-80MB fills in 30-70 seconds
5. "Collect on allocation" triggers another Full GC
6. Repeat forever

### The "Double-Tap" Pattern

Sometimes the post-GC free space is still below the allocation threshold, triggering an immediate second Full GC within 1 second. Two 200ms+ pauses back-to-back are enough to drop packets on CPU-attached ports and create visible network blips.

## The `-XX:MaxHeapFree` Red Herring

Ubiquiti's service file sets:
```
UNIFI_NATIVE_OVERRIDE_OPTS="-XX:StackSize=512K -XX:MaxHeapFree=0"
```

And `/etc/default/unifi` sets:
```
UNIFI_NATIVE_OPTS="... -XX:MaxHeapFree=128M"
```

Since `OVERRIDE_OPTS` is appended after `NATIVE_OPTS` on the command line, `MaxHeapFree=0` was always the effective value. But it doesn't matter - **GraalVM ignores both**. Neither `MaxHeapFree` nor `StackSize` are valid GraalVM flags.

All of the following had no effect:
- `MaxHeapFree=128M` (stock)
- `MaxHeapFree=256M`
- `MaxHeapFree=512M`
- `MaxHeapFree=768M`

The actual lever is **`-Xms`**, which sets the committed heap floor.

## Profiling Results

### Stock vs. Tuned (2.7 hours uptime)

| Metric | Stock (`-Xms128M`) | Tuned (`-Xms384M`) | Improvement |
|---|---|---|---|
| Total GC events | 1,769 | 343 | **5.2x fewer** |
| Full GCs | 132 | 32 | **4.1x fewer** |
| Full GCs/hour | 48.4 | 11.7 | **4.1x fewer** |
| Full GC interval | avg 73s | avg 304s | **4.2x longer** |
| Double-taps (<3s) | 3 | 0 | **Eliminated** |
| CPU time in GC | 0.646% | 0.213% | **3x less** |

### Progression Over Time (Tuned `-Xms384M`)

| Uptime | Total GC | Full GCs | Full GC Interval | Double-taps | CPU in GC |
|---|---|---|---|---|---|
| 14 min | 17 | 2 | avg 376s | 0 | 0.26% |
| 36 min | 32 | 6 | avg 386s | 0 | 0.157% |
| 1.2 hr | 69 | 12 | avg 372s | 0 | 0.156% |
| 2.7 hr | 343 | 32 | avg 304s | 0 | 0.213% |

Hourly breakdown:

| Hour | Full GCs | Total GCs | Avg Full GC interval |
|---|---|---|---|
| 0 | 10 | 56 | 375s |
| 1 | 11 | 81 | 323s |
| 2 | 11 | 206 | 220s |

Intervals degrade from 375s to 220s by hour 2 as the controller warms up and the live data set grows. Total incremental GCs spiked in hour 2 (206 vs 81). Still 3x better than stock (73s avg at the same uptime). If degradation continues past 24 hours, `-Xms512M` may be warranted.

### Long-Term Degradation (Stock and Moderate Configs)

| Config | Full GC at 1hr | At 23hr | Outcome |
|---|---|---|---|
| Stock (`Xms128M, Xmx640M`) | 18-26s | worse | Thrashing |
| `Xmx640M, MaxHeapFree=256M` | 18-26s | worse | Thrashing (MaxHeapFree was ignored) |
| `Xmx768M, MaxHeapFree=256M` | 90-220s | 25-40s | Delayed degradation - live data grew from 105MB to 148MB |

The live data set grows over time (105MB at hour 1 -> 148MB at hour 23). With stock `-Xms`, there's less and less headroom as the live set grows, so Full GC frequency accelerates. With `-Xms384M`, there's ~250MB of headroom even with a 148MB live set - enough to maintain stable intervals.

## Correlation With Packet Loss

Direct correlation was observed between Full GC events and packet drops:

- JVM Full GC at `12:00:23 CDT` with 364ms pause
- Gateway packet drop logged at `12:00:22 CDT`
- Matched to the second

The mechanism: a 200-350ms stop-the-world pause freezes the JVM thread that handles certain CPU-attached port operations, causing packet buffers to overflow.

## Monitoring GC

```bash
# Watch GC events in real time (PrintGC is enabled by default)
journalctl -u unifi -f | grep -i "gc"

# Count Full GCs in the last hour
journalctl -u unifi --since "1 hour ago" | grep -c "Full GC"

# Check current heap settings
ps aux | grep unifi | grep -oP '\-Xm[sx]\S+'
```

## What Flags Does GraalVM Actually Recognize?

From SubstrateVM documentation:

| Flag | Recognized | Purpose |
|---|---|---|
| `-Xms` | **Yes** | Minimum (floor) heap size |
| `-Xmx` | **Yes** | Maximum heap size |
| `-Xss` | **Yes** | Thread stack size |
| `-XX:+PrintGC` | **Yes** | Print GC events to stdout |
| `-XX:+ExitOnOutOfMemoryError` | **Yes** | Exit JVM on OOM |
| `-XX:MaxHeapFree` | **No** | Android ART flag, silently ignored |
| `-XX:MaxHeapFreeRatio` | **No** | HotSpot flag, not in SubstrateVM |
| `-XX:StackSize` | **No** | Not a standard flag (use `-Xss`) |
