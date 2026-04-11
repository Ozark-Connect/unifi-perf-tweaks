# jvm-heap-tuning

**Script:** [`scripts/05-jvm-heap-tuning.sh`](../scripts/05-jvm-heap-tuning.sh)
**Compatibility:** All UniFi Cloud Gateway models
**Risk level:** Low - does not restart the controller; settings apply on next restart

## Problem

The UniFi controller is a **GraalVM Native Image** (Liberica NIK, SubstrateVM, Serial GC). The stock JVM configuration ships with a low `-Xms` (minimum heap size), which causes the Serial GC to shrink the heap after each Full GC back to near the live data size (~120MB). This leaves only 30-80MB of headroom for new allocations.

The result:
1. Full GC fires every 30-70 seconds (150-350ms stop-the-world pauses)
2. "Double-tap" patterns where two Full GCs fire within 1 second
3. On models with CPU-attached network ports, each GC pause drops packets

### Why this is fundamentally hard to fix

GraalVM Native Image was designed for **serverless and microservices** — fast startup, small footprint, return RAM to the OS as quickly as possible. The Adaptive2 collection policy has `MIN_HEAP_FREE_RATIO=0` hardcoded, meaning it will always try to shrink the heap to just above live data. This is ideal for cloud functions in 256MB containers, but terrible for a long-running server.

The UniFi controller *is* a long-running server — Spring Boot, Netty, MongoDB client, websockets for dozens of devices. HotSpot's G1 or ZGC would handle this trivially with their server-oriented adaptive sizing, but Ubiquiti uses GraalVM Community Edition (Liberica NIK), which only offers Serial GC with almost no tuning knobs. The GC algorithm is baked into the native image at build time and cannot be changed at runtime.

Locking the heap (`-Xms` == `-Xmx`) is the best available workaround. It prevents total heap shrinking but can't stop the adaptive policy from resizing generations internally, so improvement is significant (~2-3x fewer Full GCs) but not total.

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

| IPS / IDS Status | Heap (locked) | Rationale |
|---|---|---|
| **Off / Off** | 768M | ~638MB headroom above ~130MB live data → 400-500s Full GC intervals |
| **IDS on or IPS on** | 640M | Matches Ubiquiti's stock Xmx, known to fit alongside Suricata (~778MB) |

These are configurable at the top of the script.

### How "IPS" Is Detected

The script reads UniFi Network's own configuration state to decide which heap profile to apply. Specifically, it parses `/data/udapi-config/ubios-udapi-server/ubios-udapi-server.state` (a JSON file persisted on `/data`) and checks `services.idsIps.enabled`.

**Why parse the state file and not check for a running process?** Because the boot script runs very early in the startup sequence — well before Suricata's own systemd unit has launched. A `pidof suricata` check at that point reliably returns "nothing", so the script would pick the wrong heap every boot on a gateway that actually has IPS enabled. The JSON state file is persistent across reboots and reflects the *configured* state, not the *currently-running* state, so it's race-free.

**IDS vs IPS — why the same heap size?** UniFi groups both modes under the same `services.idsIps.enabled` flag, with a separate `mode` field distinguishing "Detect only" (IDS) from "Detect and block" (IPS). The RAM footprint is identical across both modes because **Suricata runs in pcap mode either way** — it observes traffic out-of-band via libpcap on the bridge interfaces (you'll see `"mode": "pcap-high"` in the state file), never in the forwarding path. The "Detect and block" behavior is **reactive**: Suricata raises alerts and fires blocks to another component based on what it saw, rather than being inline. So from the JVM's perspective there's no difference to account for — both modes get the same 640M profile, and there's no separate "IDS only" tier.

**Where to find the toggle in the UI:** Settings → CyberSecure → Intrusion Prevention. The main switch there flips `services.idsIps.enabled` to `true`, and the "Detection Mode" dropdown picks between "Notify" (IDS — detect only) and "Notify and Block" (IPS — detect and block). Either mode triggers the 640M heap profile in this script.

**Detection fallbacks**, in order:

1. **JSON parse of `services.idsIps.enabled`** (primary, reliable at boot and runtime)
2. **`pidof suricata`** (secondary — only reached if python3 is missing, the state file is unreadable, or JSON parsing raised an exception)
3. If both fail: default to the no-IPS profile (768M)

The only blind spot is "state file path changes in future firmware *and* the script runs before Suricata starts *and* IPS is actually enabled" — on that combination, the script would silently write 768M on an IPS box. If you hit that, the symptom is memory pressure or OOM after a reboot; mitigation is to edit the `SURICATA_ACTIVE=true` branch at the top of the script directly until the detection is updated.

### Verifying the Detection

To check what the script will decide on your gateway before running it:

```bash
python3 -c "
import json
with open('/data/udapi-config/ubios-udapi-server/ubios-udapi-server.state') as f:
    state = json.load(f)
ids = state.get('services', {}).get('idsIps', {})
print(f\"enabled = {ids.get('enabled', False)}\")
print(f\"mode    = {ids.get('mode', '(not set)')}\")
"
```

`enabled = True` → script will pick **640M**. `enabled = False` or missing → script will pick **768M**.

### Settings Persistence

- Stored in `/etc/default/unifi` (overlay filesystem)
- **Survives UniFi Network upgrades** (e.g., 10.2.104 -> 10.2.105) -- confirmed
- **Does NOT survive UniFi OS upgrades** - the boot script reapplies on next boot
- Does NOT restart the controller - applies on next natural restart

## Profiling Results

> **Status: Testing (2026-04-03).** Locked heap (`-Xms` == `-Xmx`) confirmed as the only effective configuration. 22.75-hour soak complete: 2.3x fewer Full GCs, 5.7x fewer double-taps vs best unlocked config.

### Configurations tested

Five configurations were tested on a production UCG-Fiber (Suricata OFF, MongoDB on SSD), each soaked for hours to days:

| Config | Soak | Full GCs/hr | Double-taps | Result |
|---|---|---|---|---|
| Stock (`Xms=128M Xmx=640M`) | baseline | 46.7 | 10 at 5hr | Thrashing |
| `Xms=384M Xmx=768M` | 28hr | 72.9 | 170 | Heap compressed 335→165M in 50min |
| `Xms=512M Xmx=768M` | 2.5hr | ~42 | 0 | Same compression pattern |
| `Xms=512M MaxHeapFree=384M MinHeapSize=512M` | 1hr | ~26 | 0 | MaxHeapFree/MinHeapSize had zero effect |
| **`Xms=768M Xmx=768M` (locked)** | **22.75hr** | **32.1** | **30** | **Best: 2.3x fewer GCs, 5.7x fewer double-taps** |

### Locked heap results (`-Xms768M -Xmx768M`, 22.75 hours)

**Overall: 732 Full GCs, 32.1/hr, 30 double-taps**

The locked heap prevents total committed heap from shrinking, but the Adaptive2 policy still resizes generations internally (shrinks old gen, gives space to eden). This causes intervals to compress from 400-700s (first 2 hours) to a steady state of 24-42/hr.

| Metric | Unlocked best (Xms=384M, 28hr) | **Locked (Xms=Xmx=768M, 22.75hr)** | Improvement |
|---|---|---|---|
| Overall Full GCs/hr | 72.9 | **32.1** | **2.3x fewer** |
| Double-taps | 170 | **30** | **5.7x fewer** |
| Worst single hour | 264 | **70** | **3.8x better** |
| Typical steady state | 28-118/hr (erratic) | **24-42/hr (consistent)** | More stable |

The locked heap's steady-state behavior **oscillates rather than monotonically degrading** — intervals periodically recover to 100-260s before tightening again. Unlocked configs compress monotonically and never recover.

### Memory impact

| Resource | Stock | Locked 768M | Delta |
|---|---|---|---|
| JVM RSS | ~300-400MB | 375MB at 22.75hr | Minimal |
| System available | ~1,050MB | 1,082MB | Fine |
| Swap used | ~250MB | ~262MB | ~same |

The locked heap commits 768MB from startup but Linux only backs pages with physical RAM as they're touched. Actual RSS stays around 375MB — not the full 768MB.

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

### Early locked-heap snapshot (85 minutes)

This was the first checkpoint that confirmed locking `-Xms` == `-Xmx` works. It's historical — the 22.75-hour soak data above is the final result — but the 85-minute numbers are a useful comparison point because they show the first-order behavior before steady-state settling.

| Metric | Unlocked (best of 3 configs) | **Locked (at 85 min)** |
|---|---|---|
| Full GCs/hr | 26-44 | **10.6** |
| Full GC interval | 28-79s (compressing) | **345-525s (stable)** |
| Heap before GC | 155-195M (compressed) | **329-338M (rock solid)** |

At this early point, the locked heap stayed at 329-338M before every Full GC with no compression. Intervals later tightened as the Adaptive2 policy resized generations internally — see the 22.75-hour numbers above for the steady-state result.

### Assessment

The locked heap configuration (`-Xms` == `-Xmx`) provides a clear, stable improvement over every unlocked configuration tested:
- **2.3x fewer Full GCs** than the best unlocked config at comparable soak times (22.75hr data)
- **5.7x fewer double-taps** (170 → 30) — not zero, but a dramatic reduction in the rapid-fire GC storms that cause packet loss blips
- **Consistent steady-state** (24-42/hr) vs erratic unlocked behavior (28-118/hr)
- **Total committed heap never compresses** — the Adaptive2 policy still resizes generations internally, but the overall commit floor holds

The improvement over stock is even larger, but the meaningful comparison is "locked vs best unlocked config" because stock is a baseline nobody should run anyway.

Deployment order: the MongoDB SSD offload (06) and journald volatile (10) scripts target the eMMC write pressure that's the dominant cause of packet loss. JVM heap locking is a complementary fix that reduces GC frequency and eliminates most (not all) double-tap storms. On boot, 05 must run before 06 so the unifi restart triggered by 06 picks up the new heap config in one pass — see [README boot order](../README.md#boot-order).

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

`/etc/default/unifi` is on the overlay filesystem, which means the script's edits **persist across reboots**. Simply removing the boot script is not enough — the JVM config stays locked at whatever value the script wrote. The overlay resets to stock only on a UniFi OS upgrade.

To revert immediately:

```bash
# Restore stock settings. Handles both the 640M (IPS on) and 768M
# (IPS off) profiles by matching any -Xms/-Xmx value.
sed -i 's/-Xms[0-9]\+[MmGg]/-Xms128M/' /etc/default/unifi
sed -i 's/-Xmx[0-9]\+[MmGg]/-Xmx640M/' /etc/default/unifi

# Restore the stock override flags (stripped by the boot script)
sed -i 's/^UNIFI_NATIVE_OVERRIDE_OPTS=.*/UNIFI_NATIVE_OVERRIDE_OPTS="-XX:StackSize=512K -XX:MaxHeapFree=0"/' /etc/default/unifi

# Also remove the boot script so it doesn't re-apply on next boot
rm /data/on_boot.d/05-jvm-heap-tuning.sh

# Restart unifi to pick up the reverted settings
systemctl restart unifi
```
