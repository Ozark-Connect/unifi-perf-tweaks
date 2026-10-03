#!/bin/bash
# 08-postgresql-ssd-offload.sh: Bind-mount the UniFi Network PostgreSQL data
# directory from the NVMe SSD to move its writes off the eMMC
#
# EXPERIMENTAL. Not yet verified on a gateway. See
# docs/postgresql-ssd-offload.md before deploying.
#
# UniFi Network 11.0.81+ migrates from MongoDB to PostgreSQL. The database
# lives in the UniFi OS "apps" PostgreSQL cluster (port 5434), defined in
# /etc/default/postgresql/14-apps, with this layout on the eMMC:
#
#   /data/postgresql/14/apps/.configured   marker read by pg-cluster-setup
#   /data/postgresql/14/apps/conf/         cluster config (symlinked from /etc/postgresql/14/apps)
#   /data/postgresql/14/apps/data/         PGDATA, incl. pg_wal (the write load)
#
# This script bind-mounts only data/. The cluster dir itself must stay on the
# eMMC: /sbin/pg-cluster-setup runs `rm -rf` on it and re-runs initdb if
# .configured or any conf file is missing, so a bind mount over the whole
# cluster dir that came up without those files would wipe the SSD copy.
#
# This is the PostgreSQL counterpart of 06-mongodb-ssd-offload.sh. It does
# nothing until the Network app is on PostgreSQL (no "unifi-network" database
# in the apps cluster), so it is safe to deploy ahead of the migration.
#
# Falls back to the eMMC if the SSD is missing or PostgreSQL fails to start
# on the SSD copy.
#
# Which copy is current: unlike 06, this script does NOT compare file mtimes.
# postgresql@14-apps starts on the eMMC copy at every boot, before udm-boot
# runs this script, and PostgreSQL rewrites global/pg_control on startup. So
# the eMMC copy always looks newer, and an mtime check would overwrite the
# SSD data with the eMMC snapshot on every reboot. Instead, a marker file
# ($MARKER) records that the SSD copy is authoritative:
#   - Written after every successful bind mount.
#   - Removed on every path where PostgreSQL stays on the eMMC for this boot,
#     because the eMMC copy then takes real writes.
#   - Marker present + SSD copy present: bind the SSD copy, no copy.
#   - Marker absent + SSD copy present: the eMMC copy is current. Move the
#     SSD copy aside (never deleted) and re-migrate.

# ─── Configuration ───
PG_CLUSTER="14-apps"                 # <version>-<cluster>, matches /etc/default/postgresql/<name>
NETWORK_DB="unifi-network"           # Network app database; its presence gates the offload
MAX_WAIT=60                          # Seconds to wait for the SSD mount and for PostgreSQL
STATE_DIR="/data/unifi-pg-ssd"       # eMMC, outside the Ubiquiti-managed /data/postgresql tree
MARKER="$STATE_DIR/$PG_CLUSTER.ssd-active"

LOG_TAG="postgresql-ssd-offload"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
    logger -t "$LOG_TAG" "$1"
}

# PostgreSQL stays on the eMMC for this boot, so the eMMC copy becomes the
# current one. The next boot with the SSD must re-migrate.
clear_marker() {
    if [ -e "$MARKER" ]; then
        rm -f "$MARKER"
        log "eMMC copy is now authoritative. The next successful run re-migrates it to the SSD."
    fi
}

# ─── Model check ───
# Same rule as 06-mongodb-ssd-offload.sh: UCG-Fiber and UCG-Max only. See
# that script for the rationale and the accepted shortname forms.
SHORTNAME=$(ubnt-device-info model_short 2>/dev/null)
if [ -z "$SHORTNAME" ] && [ -r /proc/ubnthal/system.info ]; then
    SHORTNAME=$(grep -i '^shortname=' /proc/ubnthal/system.info | cut -d= -f2-)
fi
case "$(echo "$SHORTNAME" | tr '[:upper:]' '[:lower:]')" in
    ucg-fiber|ucgf|ucgfiber|ucg-max|ucgmax)
        : # supported, proceed
        ;;
    *)
        log "Not running: this script supports UCG-Fiber and UCG-Max only. Detected: ${SHORTNAME:-unknown}."
        exit 0
        ;;
esac

# ─── Cluster layout ───
# Read the cluster definition the firmware ships, instead of hardcoding
# paths, so a firmware change to the layout fails closed below.
PG_ENV="/etc/default/postgresql/$PG_CLUSTER"
if [ ! -r "$PG_ENV" ]; then
    log "Not running: $PG_ENV not found. This firmware has no $PG_CLUSTER PostgreSQL cluster."
    exit 0
fi
# shellcheck disable=SC1090
. "$PG_ENV"

if [ -z "$PG_VERSION" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$DIR" ] || [ -z "$CLUSTER_PORT" ]; then
    log "ERROR: $PG_ENV is missing PG_VERSION, CLUSTER_NAME, DIR or CLUSTER_PORT. Aborting."
    exit 1
fi
PG_UNIT="postgresql@${PG_VERSION}-${CLUSTER_NAME}.service"
PG_CLUSTER_DIR="$DIR"
PG_DATA="$DIR/data"
PG_SOCKET_DIR="/var/run/postgresql"

# Check if already bind-mounted. Stock PGDATA is a subdir of /data, not
# its own mount point.
if mountpoint -q "$PG_DATA" 2>/dev/null; then
    log "Already bind-mounted to SSD. Nothing to do."
    exit 0
fi

if [ ! -e "$PG_CLUSTER_DIR/.configured" ] || [ ! -f "$PG_DATA/PG_VERSION" ]; then
    log "Not running: cluster $PG_CLUSTER is not initialized at $PG_CLUSTER_DIR. Nothing to offload."
    clear_marker
    exit 0
fi

# The config must point PostgreSQL at the PGDATA we are about to bind-mount.
CONF_DATA_DIR=$(sed -n "s/^[[:space:]]*data_directory[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
    "$PG_CLUSTER_DIR/conf/postgresql.conf" 2>/dev/null | tail -1)
if [ "$CONF_DATA_DIR" != "$PG_DATA" ]; then
    log "ERROR: postgresql.conf data_directory is '${CONF_DATA_DIR:-unset}', expected '$PG_DATA'. Unexpected layout. Aborting."
    clear_marker
    exit 1
fi

pg_ready() {
    pg_isready -q -h "$PG_SOCKET_DIR" -p "$CLUSTER_PORT" >/dev/null 2>&1
}

pg_query() {
    runuser -u postgres -- psql -X -w -h "$PG_SOCKET_DIR" -p "$CLUSTER_PORT" -d postgres -Atc "$1" 2>/dev/null
}

# A postmaster for this PGDATA is running if postmaster.pid exists and its
# first line is a live PID.
postmaster_running() {
    local pid
    [ -f "$PG_DATA/postmaster.pid" ] || return 1
    pid=$(head -1 "$PG_DATA/postmaster.pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ─── Gate: is the Network app on PostgreSQL, and is the cluster ours alone? ───
# The database list needs a running cluster. At boot the cluster may still
# be starting, so wait for it.
waited=0
while ! pg_ready; do
    if [ "$waited" -ge "$MAX_WAIT" ]; then
        log "Not running: $PG_UNIT not accepting connections after ${MAX_WAIT}s. Leaving PostgreSQL on eMMC."
        clear_marker
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done

if ! DATABASES=$(pg_query "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY 1"); then
    log "ERROR: could not list databases in cluster $PG_CLUSTER. Leaving PostgreSQL on eMMC."
    clear_marker
    exit 1
fi
if ! echo "$DATABASES" | grep -qx "$NETWORK_DB"; then
    log "Not running: no '$NETWORK_DB' database in cluster $PG_CLUSTER. The Network app is not on PostgreSQL yet."
    clear_marker
    exit 0
fi
# The apps cluster is named for sharing. Stopping it interrupts every app
# that uses it, and this script only knows how to restart the Network app's
# stack. Refuse if any other database is present.
OTHER_DBS=$(echo "$DATABASES" | grep -vx "$NETWORK_DB" | tr '\n' ' ')
if [ -n "${OTHER_DBS// /}" ]; then
    log "Not running: cluster $PG_CLUSTER also holds other databases (${OTHER_DBS% }). Shared clusters are not supported yet."
    clear_marker
    exit 0
fi

# ─── Detect the SSD mount ───
# Same detection as 06-mongodb-ssd-offload.sh.
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

waited=0
while ! detect_ssd_mount; do
    if [ "$waited" -ge "$MAX_WAIT" ]; then
        log "WARNING: No SSD mount (/volume1 or /volume/<uuid>) found after ${MAX_WAIT}s. Falling back to eMMC."
        clear_marker
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done

SSD_PG_DIR="$SSD_MOUNT/postgresql-$PG_CLUSTER"
log "SSD mount: $SSD_MOUNT"

# ─── Which copy is current ───
# See the header: decided by the marker, not by mtimes.
if [ -f "$SSD_PG_DIR/global/pg_control" ]; then
    if [ -e "$MARKER" ]; then
        log "SSD copy is authoritative. Setting up bind mount."
        NEEDS_MIGRATION=false
    else
        log "SSD copy found, but the eMMC copy is authoritative (fallback or revert since the last bind). Will re-migrate."
        NEEDS_MIGRATION=true
    fi
else
    if [ -e "$MARKER" ]; then
        log "WARNING: marker says the SSD copy is authoritative, but $SSD_PG_DIR has no data. Re-migrating from the eMMC snapshot. Changes since the last migration are lost."
    else
        log "No SSD copy found. Will perform initial migration."
    fi
    NEEDS_MIGRATION=true
fi

# ─── Stop the stack ───
# Record the running units that depend on the cluster, so the same set
# comes back up afterward. Stopping $PG_UNIT propagates the stop to every
# unit that Requires= it, so the list must be taken first.
#
# unifi.service is always restarted, because it is always stopped below. At
# boot it is often still "activating" (Type=notify), which is-active --quiet
# reports as not running. For the same reason, "activating" counts as
# running for the other dependents.
DEPENDENTS=$(systemctl list-dependencies --reverse --plain --no-legend "$PG_UNIT" 2>/dev/null \
    | sed 's/^[[:space:]]*//' | grep '\.service$' | grep -v '^postgresql' | grep -vx 'unifi.service' | sort -u)
RESTART_UNITS="unifi.service"
for u in $DEPENDENTS; do
    case "$(systemctl is-active "$u" 2>/dev/null)" in
        active|activating|reloading) RESTART_UNITS="$RESTART_UNITS $u" ;;
    esac
done

restart_stack() {
    systemctl start "$PG_UNIT"
    local u
    for u in $RESTART_UNITS; do
        systemctl start "$u"
    done
}

# Stop the Network app first so it closes its connections, then stop the
# cluster. The postgresql@ unit stops with `pg_ctlcluster -m fast`, which
# is a clean shutdown (shutdown checkpoint, no crash recovery on start).
log "Stopping unifi.service and $PG_UNIT (restart list: ${RESTART_UNITS:-none})..."
systemctl stop unifi.service
systemctl stop "$PG_UNIT"

for i in $(seq 1 30); do
    postmaster_running || break
    sleep 1
done
if postmaster_running; then
    log "ERROR: PostgreSQL still running on $PG_DATA after stop. Aborting to avoid corruption."
    clear_marker
    restart_stack
    exit 1
fi

# ─── Migration ───
# Copy to a temp dir and rename on success, so a partial copy can never be
# mistaken for a valid SSD copy. An existing SSD copy is moved aside rather
# than copied over (copying over it would leave old relation and WAL files
# behind) or deleted (it may hold the only copy of recent changes if the
# marker logic guessed wrong).
if [ "$NEEDS_MIGRATION" = true ]; then
    TMP_DIR="$SSD_PG_DIR.tmp"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    log "Copying $PG_DATA to $SSD_PG_DIR..."
    if ! cp -a "$PG_DATA"/. "$TMP_DIR"/; then
        log "ERROR: Copy to SSD failed. Leaving PostgreSQL on eMMC."
        rm -rf "$TMP_DIR"
        clear_marker
        restart_stack
        exit 1
    fi
    if [ -d "$SSD_PG_DIR" ]; then
        STALE_DIR="$SSD_PG_DIR.stale-$(date +%Y%m%d%H%M%S)"
        mv "$SSD_PG_DIR" "$STALE_DIR"
        log "Moved previous SSD copy aside to $STALE_DIR."
    fi
    mv "$TMP_DIR" "$SSD_PG_DIR"
    log "Migration complete. $(du -sh "$SSD_PG_DIR" | cut -f1) copied."
fi

# PostgreSQL refuses to start unless PGDATA is owned by the server user
# with mode 0700 or 0750. A bind mount shows the source dir's own owner and
# mode, so set them on the SSD dir. Re-applied every boot in case the dir
# was recreated.
chown postgres:postgres "$SSD_PG_DIR"
chmod 0700 "$SSD_PG_DIR"

# ─── Bind mount ───
mount --bind "$SSD_PG_DIR" "$PG_DATA"

if ! mountpoint -q "$PG_DATA" 2>/dev/null; then
    log "ERROR: Bind mount failed. PostgreSQL will use eMMC."
    clear_marker
    restart_stack
    exit 1
fi
log "Bind mount active: $PG_DATA -> $SSD_PG_DIR (SSD)"

# ─── Start on the SSD, fall back to eMMC if it does not come up ───
systemctl start "$PG_UNIT"
waited=0
while ! pg_ready; do
    if [ "$waited" -ge "$MAX_WAIT" ]; then
        break
    fi
    sleep 2
    waited=$((waited + 2))
done

if ! pg_ready; then
    log "ERROR: PostgreSQL did not start on the SSD copy within ${MAX_WAIT}s. Falling back to eMMC."
    systemctl stop "$PG_UNIT"
    for i in $(seq 1 30); do
        postmaster_running || break
        sleep 1
    done
    if ! umount "$PG_DATA"; then
        log "ERROR: umount $PG_DATA failed. Not restarting PostgreSQL. Manual recovery needed (see docs/postgresql-ssd-offload.md)."
        exit 1
    fi
    clear_marker
    restart_stack
    exit 1
fi

# The SSD copy is live and takes the writes from here on.
mkdir -p "$STATE_DIR"
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $SSD_PG_DIR" > "$MARKER"

for u in $RESTART_UNITS; do
    systemctl start "$u"
done
log "PostgreSQL cluster $PG_CLUSTER started on SSD. Restarted: ${RESTART_UNITS:-none}."
