#!/bin/bash
# 11-jvm-heap-tuning.sh: Tune UniFi controller JVM heap to prevent GC thrashing
#
# The UniFi controller runs on GraalVM Native Image (SubstrateVM, Serial GC).
# The stock -Xms is too low, causing the heap to shrink after each Full GC
# back to near live data size (~120MB). With only 30-80MB headroom, Full GC
# fires every 30-70 seconds with 150-350ms stop-the-world pauses.
#
# On models with CPU-attached network ports (UCG-Fiber SFP+, etc.), these
# GC pauses directly cause packet drops.
#
# Fix: Set -Xms high enough to prevent heap shrinking. Also cleans up dead
# Android ART flags (-XX:MaxHeapFree, -XX:StackSize) that Ubiquiti left in
# the service file - GraalVM silently ignores them.
#
# The script auto-detects Suricata/IPS and adjusts heap sizes accordingly.
# Does NOT restart the controller - settings apply on next restart.
#
# Compatible with all UniFi Cloud Gateway models.

LOG_TAG="jvm-heap-tuning"
UNIFI_DEFAULTS="/etc/default/unifi"

# ─── Heap sizes ───
# Adjust these if your site has different memory constraints.
# With IPS:    Suricata uses ~778MB, so we use a smaller Xms to leave room.
# Without IPS: More RAM available, larger Xms keeps GC intervals longer.
XMS_WITH_IPS="256M"
XMX_WITH_IPS="768M"
XMS_WITHOUT_IPS="384M"
XMX_WITHOUT_IPS="768M"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
}

if [ ! -f "$UNIFI_DEFAULTS" ]; then
    log "ERROR: $UNIFI_DEFAULTS not found"
    exit 1
fi

# Detect if Suricata/IPS is configured to run
SURICATA_ACTIVE=false
if pidof suricata > /dev/null 2>&1; then
    SURICATA_ACTIVE=true
elif grep -q "ips.*enabled.*true" /data/udapi-config/ubios-udapi-server/ubios-udapi-server.state 2>/dev/null; then
    SURICATA_ACTIVE=true
fi

if [ "$SURICATA_ACTIVE" = true ]; then
    TARGET_XMS="$XMS_WITH_IPS"
    TARGET_XMX="$XMX_WITH_IPS"
    log "Suricata/IPS detected. Using conservative heap: Xms=${TARGET_XMS}, Xmx=${TARGET_XMX}"
else
    TARGET_XMS="$XMS_WITHOUT_IPS"
    TARGET_XMX="$XMX_WITHOUT_IPS"
    log "No Suricata/IPS. Using optimal heap: Xms=${TARGET_XMS}, Xmx=${TARGET_XMX}"
fi

# Read current values
CURRENT=$(grep "^UNIFI_NATIVE_OPTS" "$UNIFI_DEFAULTS")
CURRENT_XMS=$(echo "$CURRENT" | grep -oP '\-Xms\K[^ "]+')
CURRENT_XMX=$(echo "$CURRENT" | grep -oP '\-Xmx\K[^ "]+')

if [ "$CURRENT_XMS" = "$TARGET_XMS" ] && [ "$CURRENT_XMX" = "$TARGET_XMX" ]; then
    log "Already configured. Xms=${CURRENT_XMS}, Xmx=${CURRENT_XMX}"
    exit 0
fi

log "Updating: Xms=${CURRENT_XMS}->${TARGET_XMS}, Xmx=${CURRENT_XMX}->${TARGET_XMX}"

# Apply Xms and Xmx to UNIFI_NATIVE_OPTS
sed -i "s/-Xms[^ \"]*/-Xms${TARGET_XMS}/" "$UNIFI_DEFAULTS"
sed -i "s/-Xmx[^ \"]*/-Xmx${TARGET_XMX}/" "$UNIFI_DEFAULTS"

# Strip MaxHeapFree from NATIVE_OPTS (Android ART flag, ignored by GraalVM)
sed -i "/^UNIFI_NATIVE_OPTS/s/ -XX:MaxHeapFree=[^ \"]*//g" "$UNIFI_DEFAULTS"

# Override UNIFI_NATIVE_OVERRIDE_OPTS to remove the service file's dead ART flags.
# The service file sets: UNIFI_NATIVE_OVERRIDE_OPTS="-XX:StackSize=512K -XX:MaxHeapFree=0"
# Neither flag is recognized by GraalVM. Replace with valid flags only.
if grep -q "^UNIFI_NATIVE_OVERRIDE_OPTS" "$UNIFI_DEFAULTS"; then
    sed -i "s/^UNIFI_NATIVE_OVERRIDE_OPTS=.*/UNIFI_NATIVE_OVERRIDE_OPTS=\"-XX:+ExitOnOutOfMemoryError\"/" "$UNIFI_DEFAULTS"
else
    echo 'UNIFI_NATIVE_OVERRIDE_OPTS="-XX:+ExitOnOutOfMemoryError"' >> "$UNIFI_DEFAULTS"
fi

# Verify
UPDATED=$(grep "^UNIFI_NATIVE" "$UNIFI_DEFAULTS")
log "Updated: $UPDATED"

log "Settings will take effect on next UniFi controller restart."
