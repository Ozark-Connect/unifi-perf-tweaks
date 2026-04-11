#!/bin/bash
# 05-jvm-heap-tuning.sh: Tune UniFi controller JVM heap to prevent GC thrashing
#
# The UniFi controller is a GraalVM Native Image (Liberica NIK, SubstrateVM,
# Serial GC with Adaptive2 collection policy). The adaptive policy aggressively
# shrinks the committed heap after each Full GC — no runtime flag prevents this.
#
# The only reliable fix is locking the heap: -Xms equal to -Xmx. This prevents
# the adaptive policy from shrinking, maintaining hundreds of MB of headroom
# between live data (~130MB) and the committed heap.
#
# Without locking, Full GC fires every 30-70 seconds with 150-350ms
# stop-the-world pauses. With locking, intervals extend to 400-500+ seconds.
#
# On models with CPU-attached network ports (UCG-Fiber SFP+, etc.), these
# GC pauses can cause packet drops.
#
# Why not MaxHeapFree or MinHeapSize?
#   - MaxHeapFree is an UPPER BOUND (cap on free space), not a floor
#   - MinHeapSize only sets initial sizes, not enforced during shrinking
#   - The Adaptive2 policy has MIN_HEAP_FREE_RATIO=0 hardcoded
#   - See docs/jvm-heap-tuning.md for source code analysis
#
# The script auto-detects Suricata/IPS and adjusts heap sizes accordingly.
# Does NOT restart the controller - settings apply on next restart.
#
# Compatible with all UniFi Cloud Gateway models.

LOG_TAG="jvm-heap-tuning"
UNIFI_DEFAULTS="/etc/default/unifi"

# ─── Heap sizes (locked: Xms == Xmx) ───
# The heap MUST be locked (Xms == Xmx) to prevent the Adaptive2 GC policy
# from shrinking it. Any gap between Xms and Xmx will be exploited by the
# adaptive policy within ~50 minutes of runtime.
#
# With IPS:    Suricata uses ~778MB. 640M matches Ubiquiti's stock Xmx and is
#              known to fit alongside Suricata in RAM.
# Without IPS: 768M gives ~638MB headroom above ~130MB live data, producing
#              Full GC intervals of 400-500+ seconds.
HEAP_WITH_IPS="640M"
HEAP_WITHOUT_IPS="768M"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
}

if [ ! -f "$UNIFI_DEFAULTS" ]; then
    log "ERROR: $UNIFI_DEFAULTS not found"
    exit 1
fi

# Detect whether Suricata/IPS is configured to run.
#
# The UniFi Network IPS/IDS flag lives at services.idsIps.enabled in
# /data/udapi-config/ubios-udapi-server/ubios-udapi-server.state (a JSON
# config file persisted across reboots). Reading this file is the only
# reliable detection at boot time — `pidof suricata` races with
# Suricata's own startup and will return false if our boot script runs
# before it, causing us to pick the wrong (larger) heap profile.
#
# Parse with python3 + json for correctness; fall back to `pidof
# suricata` only if we can't read the state file (e.g., missing
# python3, unusual config path, malformed JSON).
SURICATA_ACTIVE=false
STATE_FILE="/data/udapi-config/ubios-udapi-server/ubios-udapi-server.state"
STATE_CHECKED=false

if command -v python3 >/dev/null 2>&1 && [ -r "$STATE_FILE" ]; then
    python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        state = json.load(f)
    sys.exit(0 if state.get('services', {}).get('idsIps', {}).get('enabled', False) else 10)
except Exception:
    sys.exit(20)
" >/dev/null 2>&1
    RC=$?
    case $RC in
        0)  SURICATA_ACTIVE=true;  STATE_CHECKED=true ;;
        10) SURICATA_ACTIVE=false; STATE_CHECKED=true ;;
        *)  : ;;
    esac
fi

# Fallback: process check. Unreliable at boot time but useful for manual
# live runs and for firmware variants where the state file path differs.
if [ "$STATE_CHECKED" = false ] && pidof suricata >/dev/null 2>&1; then
    SURICATA_ACTIVE=true
fi

if [ "$SURICATA_ACTIVE" = true ]; then
    TARGET_HEAP="$HEAP_WITH_IPS"
    log "Suricata/IPS detected. Using locked heap: ${TARGET_HEAP}"
else
    TARGET_HEAP="$HEAP_WITHOUT_IPS"
    log "No Suricata/IPS. Using locked heap: ${TARGET_HEAP}"
fi

# Read current values
CURRENT=$(grep "^UNIFI_NATIVE_OPTS" "$UNIFI_DEFAULTS")
CURRENT_XMS=$(echo "$CURRENT" | grep -oP '\-Xms\K[^ "]+')
CURRENT_XMX=$(echo "$CURRENT" | grep -oP '\-Xmx\K[^ "]+')

if [ "$CURRENT_XMS" = "$TARGET_HEAP" ] && [ "$CURRENT_XMX" = "$TARGET_HEAP" ]; then
    log "Already configured. Heap locked at ${TARGET_HEAP}"
    exit 0
fi

log "Updating: Xms=${CURRENT_XMS}->${TARGET_HEAP}, Xmx=${CURRENT_XMX}->${TARGET_HEAP}"

# Apply locked heap to UNIFI_NATIVE_OPTS
sed -i "s/-Xms[^ \"]*/-Xms${TARGET_HEAP}/" "$UNIFI_DEFAULTS"
sed -i "s/-Xmx[^ \"]*/-Xmx${TARGET_HEAP}/" "$UNIFI_DEFAULTS"

# Strip MaxHeapFree and MinHeapSize from NATIVE_OPTS if present
# (these flags don't prevent shrinking — see docs/jvm-heap-tuning.md)
sed -i "/^UNIFI_NATIVE_OPTS/s/ -XX:MaxHeapFree=[^ \"]*//g" "$UNIFI_DEFAULTS"
sed -i "/^UNIFI_NATIVE_OPTS/s/ -XX:MinHeapSize=[^ \"]*//g" "$UNIFI_DEFAULTS"

# Override UNIFI_NATIVE_OVERRIDE_OPTS to remove the service file's stock flags.
# The service file sets: UNIFI_NATIVE_OVERRIDE_OPTS="-XX:StackSize=512K -XX:MaxHeapFree=0"
# Without this override, any flags we set could be clobbered (last flag wins).
if grep -q "^UNIFI_NATIVE_OVERRIDE_OPTS" "$UNIFI_DEFAULTS"; then
    sed -i "s/^UNIFI_NATIVE_OVERRIDE_OPTS=.*/UNIFI_NATIVE_OVERRIDE_OPTS=\"-XX:+ExitOnOutOfMemoryError\"/" "$UNIFI_DEFAULTS"
else
    echo 'UNIFI_NATIVE_OVERRIDE_OPTS="-XX:+ExitOnOutOfMemoryError"' >> "$UNIFI_DEFAULTS"
fi

# Verify
UPDATED=$(grep "^UNIFI_NATIVE" "$UNIFI_DEFAULTS")
log "Updated: $UPDATED"

log "Settings will take effect on next UniFi controller restart."
