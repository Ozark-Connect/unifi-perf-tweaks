#!/bin/bash
# 20-mongodb-ssd-offload.sh: Bind-mount MongoDB from NVMe SSD to eliminate eMMC writes
#
# MongoDB on eMMC causes cyclical packet loss from bulk delete operations
# (15,000 docs every 2-3 hours). The eMMC flash controller's garbage collection
# stalls I/O for 30+ minutes afterward, dropping packets on CPU-attached ports.
#
# This script bind-mounts MongoDB's data directory from the NVMe SSD over the
# eMMC location. On first run, it migrates the existing data. On subsequent
# boots, it sets up the bind mount directly.
#
# Requires: NVMe SSD with a /volume* mount point (UCG-Fiber, UCG-Max, or
# any model with an internal SSD). Not needed on eMMC-only models
# (UCG-Lite, etc.) - those models don't have an SSD to offload to.
#
# Falls back gracefully to eMMC if the SSD is not available.

# ─── Configuration ───
SSD_DB_SUBDIR="unifi-db"             # Subdir on the SSD for MongoDB data
EMMC_DB_DIR="/data/unifi/data/db"    # Stock MongoDB location (eMMC)
MAX_WAIT=60                          # Seconds to wait for SSD mount at boot

LOG_TAG="mongodb-ssd-offload"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
    logger -t "$LOG_TAG" "$1"
}

# ─── Model check ───
# Only UCG-Fiber is tested and supported. Other UCG models (UCG-Max) may
# work but are unverified; non-UCG models (UDM-Pro, UDM-SE, UDM-Pro Max)
# use entirely different storage layouts and running this script could
# land a bind mount in the wrong place. Refuse to run on anything else.
MODEL_INFO="/proc/ubnthal/system.info"
if [ -r "$MODEL_INFO" ] && grep -qi '^shortname=UCGF$' "$MODEL_INFO"; then
    : # UCG-Fiber, proceed
else
    MODEL_NAME=$(grep -i '^name=' "$MODEL_INFO" 2>/dev/null | cut -d= -f2-)
    log "Not running: this script is for UCG-Fiber only. Detected: ${MODEL_NAME:-unknown}."
    exit 0
fi

# Detect the SSD mount point. Firmware 5.0.x and older mount the NVMe at
# /volume1; 5.1.7+ EA mounts it at /volume/<uuid>/. On success, sets
# SSD_MOUNT and returns 0. Returns 1 if no SSD mount is found.
detect_ssd_mount() {
    if mountpoint -q /volume1 2>/dev/null; then
        SSD_MOUNT=/volume1
        return 0
    fi
    local d mp
    for d in /volume/*/; do
        [ -d "$d" ] || continue
        mp="${d%/}"
        if mountpoint -q "$mp" 2>/dev/null; then
            SSD_MOUNT="$mp"
            return 0
        fi
    done
    local t
    t=$(findmnt -no TARGET /dev/md3 2>/dev/null | head -1)
    if [ -n "$t" ]; then
        SSD_MOUNT="$t"
        return 0
    fi
    return 1
}

# Check if already bind-mounted
# mountpoint returns 0 only if the path is a mount point itself (not just a subdirectory
# of a mounted filesystem). Stock MongoDB is just a subdir of /data, not its own mount.
if mountpoint -q "$EMMC_DB_DIR" 2>/dev/null; then
    log "Already bind-mounted to SSD. Nothing to do."
    exit 0
fi

# Wait for an SSD mount to appear (may take a moment after boot)
waited=0
while ! detect_ssd_mount; do
    if [ "$waited" -ge "$MAX_WAIT" ]; then
        log "WARNING: No SSD mount (/volume1 or /volume/<uuid>) found after ${MAX_WAIT}s. Falling back to eMMC."
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done

SSD_DB_DIR="$SSD_MOUNT/$SSD_DB_SUBDIR"
if [ "$waited" -gt 0 ]; then
    log "Waited ${waited}s for SSD to mount at $SSD_MOUNT."
else
    log "SSD mount: $SSD_MOUNT"
fi

# Stop unifi and guarantee mongod is fully exited. Sets RESTART_UNIFI=true
# if we stopped anything. Returns 0 if mongod is down, 1 if it refused.
#
# Both the first-run cp and the bind mount need mongod truly down: the cp
# would otherwise capture a torn WiredTiger snapshot, and the bind mount
# would clobber a live data directory.
#
# On modern firmware, mongod runs under its own systemd unit
# (unifi-mongodb.service) which includes a bash wrapper, the mongod
# process, and a watchdog - all in the same cgroup. That unit declares:
#   - ExecStop=/usr/bin/mongod --shutdown    (clean WiredTiger shutdown)
#   - KillMode=control-group                  (SIGTERM the whole cgroup)
#   - Restart=always                          (watchdog respawns on exit)
# unifi.service declares Requires=unifi-mongodb.service, so stopping
# unifi-mongodb also cascades to stop unifi. This is the correct and
# safe way to stop the whole stack: `systemctl stop unifi` alone does
# NOT stop mongod because they're separate units, and `pkill mongod`
# would be respawned by systemd within RestartSec.
#
# Older firmware without a separate mongodb unit falls back to stopping
# unifi and escalating to SIGTERM if mongod doesn't exit.
RESTART_UNIFI=false
stop_mongod_and_unifi() {
    if systemctl list-unit-files unifi-mongodb.service >/dev/null 2>&1; then
        if systemctl is-active --quiet unifi-mongodb.service 2>/dev/null; then
            log "Stopping unifi-mongodb.service (clean mongod shutdown + cascades to unifi)..."
            systemctl stop unifi-mongodb.service
            RESTART_UNIFI=true
        fi
    else
        if systemctl is-active --quiet unifi 2>/dev/null; then
            log "Stopping unifi.service (no unifi-mongodb unit present)..."
            systemctl stop unifi
            RESTART_UNIFI=true
            for i in $(seq 1 30); do
                pgrep -x mongod >/dev/null 2>&1 || break
                sleep 1
            done
            if pgrep -x mongod >/dev/null 2>&1; then
                log "mongod still running after unifi stop. Sending SIGTERM..."
                pkill -TERM -x mongod
                for i in $(seq 1 15); do
                    pgrep -x mongod >/dev/null 2>&1 || break
                    sleep 1
                done
            fi
        fi
    fi

    if pgrep -x mongod >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Check if SSD copy exists
if [ -f "$SSD_DB_DIR/WiredTiger" ]; then
    log "SSD copy found. Setting up bind mount."
    NEEDS_MIGRATION=false
else
    log "No SSD copy found. Will perform initial migration."
    NEEDS_MIGRATION=true
fi

# Stop mongod before touching anything. Do this once and reuse for both
# migration and bind mount, so we never run them against a live database.
if ! stop_mongod_and_unifi; then
    log "ERROR: mongod still running after SIGTERM. Aborting to avoid corruption."
    if [ "$RESTART_UNIFI" = true ]; then
        log "Restarting unifi to restore service on eMMC..."
        systemctl start unifi
    fi
    exit 1
fi

# First-run migration: copy eMMC → SSD now that mongod is guaranteed down
if [ "$NEEDS_MIGRATION" = true ]; then
    mkdir -p "$SSD_DB_DIR"
    log "Copying $EMMC_DB_DIR to $SSD_DB_DIR..."
    cp -a "$EMMC_DB_DIR"/* "$SSD_DB_DIR"/
    log "Migration complete. $(du -sh "$SSD_DB_DIR" | cut -f1) copied."
fi

# Apply bind mount
mount --bind "$SSD_DB_DIR" "$EMMC_DB_DIR"

if mountpoint -q "$EMMC_DB_DIR" 2>/dev/null; then
    log "Bind mount active: $EMMC_DB_DIR -> $SSD_DB_DIR (SSD)"
else
    log "ERROR: Bind mount failed. Controller will use eMMC."
    if [ "$RESTART_UNIFI" = true ]; then
        systemctl start unifi
    fi
    exit 1
fi

# Start unifi if we stopped it (or if it needs starting after migration)
if [ "$RESTART_UNIFI" = true ] || ! systemctl is-active --quiet unifi 2>/dev/null; then
    log "Starting unifi..."
    systemctl start unifi
    log "UniFi controller started on SSD-backed MongoDB."
fi
