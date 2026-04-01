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
# Requires: NVMe SSD with /volume1 mount point (UCG-Fiber, UCG-Max, or any
# model with an internal SSD). Not needed on eMMC-only models (UCG-Lite, etc.)
# - those models don't have an SSD to offload to.
#
# Falls back gracefully to eMMC if the SSD is not available.

# ─── Configuration ───
SSD_DB_DIR="/volume1/unifi-db"       # Where MongoDB data lives on SSD
EMMC_DB_DIR="/data/unifi/data/db"    # Stock MongoDB location (eMMC)
MAX_WAIT=60                          # Seconds to wait for /volume1 at boot

LOG_TAG="mongodb-ssd-offload"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
    logger -t "$LOG_TAG" "$1"
}

# Check if already bind-mounted
# mountpoint returns 0 only if the path is a mount point itself (not just a subdirectory
# of a mounted filesystem). Stock MongoDB is just a subdir of /data, not its own mount.
if mountpoint -q "$EMMC_DB_DIR" 2>/dev/null; then
    log "Already bind-mounted to SSD. Nothing to do."
    exit 0
fi

# Wait for /volume1 to be mounted (SSD may take a moment after boot)
waited=0
while ! mountpoint -q /volume1 2>/dev/null; do
    if [ "$waited" -ge "$MAX_WAIT" ]; then
        log "WARNING: /volume1 not mounted after ${MAX_WAIT}s. Falling back to eMMC."
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done

if [ "$waited" -gt 0 ]; then
    log "Waited ${waited}s for /volume1 to mount."
fi

# Check if SSD copy exists
if [ -f "$SSD_DB_DIR/WiredTiger" ]; then
    log "SSD copy found. Setting up bind mount."
else
    log "No SSD copy found. Performing initial migration..."

    # Stop unifi if running (MongoDB stops with it)
    if systemctl is-active --quiet unifi 2>/dev/null; then
        log "Stopping unifi for migration..."
        systemctl stop unifi
        # Wait for MongoDB to fully exit
        for i in $(seq 1 30); do
            if ! pgrep -x mongod >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        RESTART_UNIFI=true
    else
        RESTART_UNIFI=false
    fi

    # Copy eMMC DB to SSD
    mkdir -p "$SSD_DB_DIR"
    log "Copying $EMMC_DB_DIR to $SSD_DB_DIR..."
    cp -a "$EMMC_DB_DIR"/* "$SSD_DB_DIR"/
    log "Migration complete. $(du -sh "$SSD_DB_DIR" | cut -f1) copied."
fi

# Stop unifi if running (need MongoDB stopped for bind mount)
if systemctl is-active --quiet unifi 2>/dev/null; then
    log "Stopping unifi for bind mount..."
    systemctl stop unifi
    for i in $(seq 1 30); do
        if ! pgrep -x mongod >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    RESTART_UNIFI=true
fi

# Apply bind mount
mount --bind "$SSD_DB_DIR" "$EMMC_DB_DIR"

if mountpoint -q "$EMMC_DB_DIR" 2>/dev/null; then
    log "Bind mount active: $EMMC_DB_DIR -> $SSD_DB_DIR (SSD)"
else
    log "ERROR: Bind mount failed. Controller will use eMMC."
    exit 1
fi

# Start unifi if we stopped it (or if it needs starting after migration)
if [ "$RESTART_UNIFI" = true ] || ! systemctl is-active --quiet unifi 2>/dev/null; then
    log "Starting unifi..."
    systemctl start unifi
    log "UniFi controller started on SSD-backed MongoDB."
fi
