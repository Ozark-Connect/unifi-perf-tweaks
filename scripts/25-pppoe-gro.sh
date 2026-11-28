#!/bin/sh
# 25-pppoe-gro.sh: load the standalone PPPoE GRO/GSO offload module (pppoe_gro.ko)
#
# Opt-in, hardened. The module is ABI-bound to ONE exact vendor kernel build:
# vermagic is not enough on this firmware (no CONFIG_MODVERSIONS), a rebuild
# with the same version string but a changed struct sk_buff would corrupt
# memory silently. So it only loads when ALL of these match a verified build:
#   - uname -r and the exact uname -v build stamp
#   - sha256 of the running kernel config (/proc/config.gz, decompressed)
#   - sha256 of the vendor pppoe.ko and qca-nss-dp.ko
#   - sha256 of the module file itself (checked again right before insmod)
# Safety:
#   - /data/pppoe-gro/disable        -> kill switch, never load
#   - /data/pppoe-gro/loading.marker -> written before insmod (no marker, no
#       load), removed 10 min after a successful load or on an orderly
#       shutdown in that window. Still present at start = the box went down
#       hard within 10 min of a load: do not load until removed by hand.
#   - delayed load: PPP_IFACE up and a PPPoE session on WAN_DEV (or a VLAN on it)
#       for 60 s without interruption, within 10 min of the start. A crash
#       never hits early boot, the box stays reachable for recovery.
#   - refuses PPP compression (deflate, bsd_comp, mppe); single instance
#       via flock.
# WAN device: the physical PPPoE receive device, WAN_DEV below or the first
# line of /data/pppoe-gro/wan_dev (e.g. eth6, not eth6.7).
# PPP interface: PPP_IFACE below or the first line of /data/pppoe-gro/ppp_iface
# (ppp0 for a PPPoE WAN1, ppp1 for WAN2, ...).
# Revert: stop downloads, rmmod pppoe_gro; or create the disable file.
# Target: UCG-Fiber, UniFi OS 6.0.11, 6.0.12, 6.0.15, 6.0.16, 6.0.17, 6.0.19, kernel 5.4.213-ui-ipq9574, module v0.4

SCRIPT_NAME="pppoe-gro"
BASE_DIR="/data/pppoe-gro"
MODULE_FILE="${BASE_DIR}/pppoe_gro.ko"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
DISABLE_FILE="${BASE_DIR}/disable"
MARKER_FILE="${BASE_DIR}/loading.marker"
WAN_DEV_FILE="${BASE_DIR}/wan_dev"
PPP_IFACE_FILE="${BASE_DIR}/ppp_iface"
LOCK_FILE="/run/${SCRIPT_NAME}.lock"
WAN_DEV="eth6"
PPP_IFACE="ppp0"
STABLE_SECS=60          # PPP_IFACE + session must be up this long without a break
WAIT_MAX_SECS=600       # give up if that does not happen within this time
POLL_SECS=5
MARKER_HOLD_SECS=600

# --- verified kernel builds ---
# One line per build the module's ABI was checked against:
#   uname -v | sha256(zcat /proc/config.gz) | sha256(pppoe.ko) | sha256(qca-nss-dp.ko)
# Add a line only after re-checking the sk_buff/napi_gro_cb layout for that
# build (see docs/pppoe-gro.md, "After a firmware update").
EXP_UNAME_R="5.4.213-ui-ipq9574"
VERIFIED_BUILDS='
#5.4.213 SMP PREEMPT Thu Oct 1 19:39:57 CST 2026|e4196f81c6df6b2367587267203835f0d36f445470b22ccfdff87b5abd361260|a40760e023b9b9f0da2bd760ac6ef7f81a4694a04c6327e61ca30e7d67c60bae|e40ec7ea163d8adc023194da5d69bea7e9f5c2c4517ce2cb316ad046cb89b0a0
#5.4.213 SMP PREEMPT Wed Oct 7 17:02:07 CST 2026|e4196f81c6df6b2367587267203835f0d36f445470b22ccfdff87b5abd361260|a40760e023b9b9f0da2bd760ac6ef7f81a4694a04c6327e61ca30e7d67c60bae|55f3b8d13807b6171b1dc0ec2a39ae3c2195c95d8e10379459b9190f8f101088
#5.4.213 SMP PREEMPT Thu Oct 22 17:59:40 CST 2026|e4196f81c6df6b2367587267203835f0d36f445470b22ccfdff87b5abd361260|a40760e023b9b9f0da2bd760ac6ef7f81a4694a04c6327e61ca30e7d67c60bae|7206e0e2fae2c91a0183001e276cbd97f99d2635cdebcd69dd7b99447001210a
#5.4.213 SMP PREEMPT Wed Oct 28 10:48:38 CST 2026|e4196f81c6df6b2367587267203835f0d36f445470b22ccfdff87b5abd361260|a40760e023b9b9f0da2bd760ac6ef7f81a4694a04c6327e61ca30e7d67c60bae|7206e0e2fae2c91a0183001e276cbd97f99d2635cdebcd69dd7b99447001210a
#5.4.213 SMP PREEMPT Tue Nov 3 11:27:33 CST 2026|e4196f81c6df6b2367587267203835f0d36f445470b22ccfdff87b5abd361260|a40760e023b9b9f0da2bd760ac6ef7f81a4694a04c6327e61ca30e7d67c60bae|7206e0e2fae2c91a0183001e276cbd97f99d2635cdebcd69dd7b99447001210a
#5.4.213 SMP PREEMPT Thu Nov 19 22:30:58 CST 2026|e4196f81c6df6b2367587267203835f0d36f445470b22ccfdff87b5abd361260|a40760e023b9b9f0da2bd760ac6ef7f81a4694a04c6327e61ca30e7d67c60bae|7206e0e2fae2c91a0183001e276cbd97f99d2635cdebcd69dd7b99447001210a
'
EXP_MODULE_SHA="2acd7a1b7921364a2460670d06c382a7f6772faf7e7508431f696da454567875"  # pppoe_gro.ko v0.4 (modules/pppoe-gro/build.sh)

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "${LOG_FILE}"
}

module_loaded() {
    lsmod | grep -q "^pppoe_gro "
}

# true if PPP_IFACE exists and is not down (ppp reports "unknown" when up)
ppp_up() {
    [ -d "/sys/class/net/${PPP_IFACE}" ] && \
        [ "$(cat "/sys/class/net/${PPP_IFACE}/operstate" 2>/dev/null)" != "down" ]
}

# true if a PPPoE session runs on WAN_DEV or on a device stacked on it (VLAN)
session_on_wan() {
    [ -r /proc/net/pppoe ] || return 1
    found=1
    while IFS=' ' read -r _id _addr dev _rest; do
        [ "$_id" = "Id" ] && continue
        [ -n "$dev" ] || continue
        if [ "$dev" = "${WAN_DEV}" ] || [ -e "/sys/class/net/${dev}/lower_${WAN_DEV}" ]; then
            found=0
        fi
    done < /proc/net/pppoe
    return $found
}

module_sha() {
    sha256sum "${MODULE_FILE}" 2>/dev/null | cut -d' ' -f1
}

# Re-exec in background so on_boot.d does not block (absolute path for nohup).
# Through sh, so a file without the executable bit (udm-boot sources those)
# works too. Exit 0 in the foreground in every case: a non-zero exit fails the
# udm-boot unit, and systemd then kills the background loaders of other scripts.
if [ "$1" != "--bg" ]; then
    mkdir -p "${BASE_DIR}"
    self=$(readlink -f "$0" 2>/dev/null)
    if [ -z "$self" ] || [ ! -f "$self" ]; then
        log "ERROR: cannot re-exec '$0' (not a file path). Run it by its full path."
        exit 0
    fi
    nohup /bin/sh "$self" --bg >/dev/null 2>&1 &
    exit 0
fi

# single instance: a second run (manual + boot) must not race the first
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "another instance is running, exiting"
    exit 0
fi

# WAN device: validate instead of silently rewriting
if [ -s "${WAN_DEV_FILE}" ]; then
    WAN_DEV=$(head -n1 "${WAN_DEV_FILE}")
fi
case "${WAN_DEV}" in
    ""|*[!A-Za-z0-9._-]*)
        log "ERROR: invalid WAN device name '${WAN_DEV}' (from ${WAN_DEV_FILE} or default). Not loading."
        exit 1 ;;
esac
if [ "${#WAN_DEV}" -gt 15 ]; then
    log "ERROR: WAN device name '${WAN_DEV}' longer than 15 characters. Not loading."
    exit 1
fi

# PPP interface: same rule, validate instead of silently falling back
if [ -s "${PPP_IFACE_FILE}" ]; then
    PPP_IFACE=$(head -n1 "${PPP_IFACE_FILE}")
fi
case "${PPP_IFACE}" in
    ppp[0-9]|ppp[1-9][0-9]) ;;
    *)
        log "ERROR: invalid PPP interface name '${PPP_IFACE}' (from ${PPP_IFACE_FILE} or default), expected ppp0 to ppp99. Not loading."
        exit 1 ;;
esac

log "start (wan_dev=${WAN_DEV}, ppp_iface=${PPP_IFACE})"

if [ ! -d "/sys/class/net/${WAN_DEV}" ]; then
    log "ERROR: WAN device '${WAN_DEV}' does not exist. Set the physical device in ${WAN_DEV_FILE}."
    exit 1
fi
for lower in /sys/class/net/"${WAN_DEV}"/lower_*; do
    if [ -e "$lower" ]; then
        log "ERROR: '${WAN_DEV}' is a stacked device (VLAN/bond). GRO sees the physical device; set that one in ${WAN_DEV_FILE}."
        exit 1
    fi
done

if [ -e "${DISABLE_FILE}" ]; then
    log "disable file present, not loading"
    exit 0
fi

if [ -e "${MARKER_FILE}" ]; then
    log "ERROR: ${MARKER_FILE} present: the box went down within ${MARKER_HOLD_SECS}s of a load without an orderly shutdown, or a load is still in its ${MARKER_HOLD_SECS}s hold. Not loading. Remove the marker by hand after investigating."
    exit 1
fi

if module_loaded; then
    log "already loaded, nothing to do"
    exit 0
fi

if [ ! -f "${MODULE_FILE}" ]; then
    log "ERROR: ${MODULE_FILE} not found"
    exit 1
fi

# --- identity checks, all must match one verified build ---
fail=0
r=$(uname -r); v=$(uname -v)
[ "$r" = "${EXP_UNAME_R}" ] || { log "MISMATCH uname -r: '$r'"; fail=1; }
cs=$(zcat /proc/config.gz 2>/dev/null | sha256sum | cut -d' ' -f1)
ps=$(sha256sum "/lib/modules/${r}/kernel/drivers/net/ppp/pppoe.ko" 2>/dev/null | cut -d' ' -f1)
ns=$(sha256sum "/lib/modules/${r}/extra/qca-nss-dp.ko" 2>/dev/null | cut -d' ' -f1)
if [ -z "$ps" ] || [ -z "$ns" ]; then
    log "MISMATCH: vendor pppoe.ko or qca-nss-dp.ko not readable"
    fail=1
fi
# exact string compare via ENVIRON (awk -v would interpret backslash escapes)
match=$(printf '%s\n' "${VERIFIED_BUILDS}" | \
    PG_V="$v" PG_C="$cs" PG_P="$ps" PG_N="$ns" awk -F'|' \
    'NF == 4 && $1 == ENVIRON["PG_V"] && $2 == ENVIRON["PG_C"] && $3 == ENVIRON["PG_P"] && $4 == ENVIRON["PG_N"] { print "ok"; exit }')
if [ "$match" != "ok" ]; then
    log "MISMATCH: running build not in the verified list: uname -v '$v', config $cs, pppoe.ko $ps, qca-nss-dp.ko $ns"
    fail=1
fi
ms=$(module_sha)
[ "$ms" = "${EXP_MODULE_SHA}" ] || { log "MISMATCH module sha256: $ms"; fail=1; }
if [ "$fail" -ne 0 ]; then
    log "ERROR: kernel build or files differ from the verified set. NOT loading. Re-verify the ABI before adding this build."
    exit 1
fi

# --- wait until PPP_IFACE and the PPPoE session on WAN_DEV are stable ---
log "waiting for ${PPP_IFACE} and a PPPoE session on ${WAN_DEV} to be up for ${STABLE_SECS}s"
waited=0
stable=0
while [ "$stable" -lt "$STABLE_SECS" ]; do
    if [ "$waited" -ge "$WAIT_MAX_SECS" ]; then
        log "ERROR: no stable ${PPP_IFACE} and PPPoE session on ${WAN_DEV} within ${WAIT_MAX_SECS}s. Not loading until the next boot or a manual start of this script."
        exit 1
    fi
    if ppp_up && session_on_wan; then
        stable=$((stable + POLL_SECS))
    else
        [ "$stable" -gt 0 ] && log "session/${PPP_IFACE} interrupted, restarting the ${STABLE_SECS}s wait"
        stable=0
    fi
    sleep "$POLL_SECS"
    waited=$((waited + POLL_SECS))
done

# --- checks right before loading ---
if ! lsmod | grep -q "^pppoe "; then
    log "ERROR: vendor pppoe module not loaded. Not loading."
    exit 1
fi
if lsmod | grep -qE "^(ppp_deflate|bsd_comp|ppp_mppe) "; then
    log "ERROR: PPP compression/MPPE module loaded, GRO would break its per-packet state. Not loading."
    exit 1
fi
if [ -e "${DISABLE_FILE}" ]; then
    log "disable file appeared during the wait, not loading"
    exit 0
fi
if module_loaded; then
    log "already loaded (loaded during the wait), nothing to do"
    exit 0
fi
ms=$(module_sha)
if [ "$ms" != "${EXP_MODULE_SHA}" ]; then
    log "ERROR: module file changed during the wait (sha256 $ms). Not loading."
    exit 1
fi

# --- load with boot-loop marker (no marker, no load) ---
# The marker holds a token of this load. Only the holder of that token removes
# it, so a holder left over from an earlier load (rmmod, marker removed by
# hand, script started again within the hold) cannot clear a newer marker.
MARKER_TOKEN="$$ $(date '+%s')"
clear_own_marker() {
    [ "$(cat "${MARKER_FILE}" 2>/dev/null)" = "${MARKER_TOKEN}" ] || return 1
    rm -f "${MARKER_FILE}"; sync
}
# An orderly stop (SIGTERM from systemd) between writing the marker and the
# start of the holder below must not leave it behind; a crash still does.
trap 'if module_loaded; then st_msg="module loaded, no boot-loop protection for this load"; else st_msg="module not loaded"; fi; clear_own_marker && log "marker cleared (stopped during the load, ${st_msg})"; exit 0' TERM INT
if ! { printf '%s\n' "${MARKER_TOKEN}" > "${MARKER_FILE}" && sync && [ -s "${MARKER_FILE}" ]; }; then
    log "ERROR: cannot write ${MARKER_FILE}, boot-loop protection unavailable. Not loading."
    exit 1
fi
if insmod "${MODULE_FILE}" wan_dev="${WAN_DEV}"; then
    sleep 2
    st=$(cat /sys/module/pppoe_gro/initstate 2>/dev/null)
    if [ "$st" = "live" ]; then
        log "loaded OK (wan_dev=${WAN_DEV}), marker held for ${MARKER_HOLD_SECS}s"
        # Hold the marker in the background. An orderly shutdown (SIGTERM from
        # systemd) clears it, a crash or power loss does not. The lock is
        # released here: the marker itself blocks a new load during the hold.
        (
            exec 9>&-
            trap 'clear_own_marker && log "marker cleared (orderly stop within hold time)"; exit 0' TERM INT
            sleep "${MARKER_HOLD_SECS}" &
            wait $!
            if clear_own_marker; then
                log "marker cleared, module considered stable"
            elif [ -e "${MARKER_FILE}" ]; then
                log "marker belongs to a newer load, left in place"
            fi
        ) &
        trap - TERM INT
        exit 0
    fi
    trap - TERM INT
    log "ERROR: module state '${st:-unknown}' after insmod, trying rmmod"
    rmmod pppoe_gro 2>/dev/null
else
    log "ERROR: insmod failed (rc=$?), see dmesg"
fi
# remove the marker only if the module is verifiably not loaded
trap - TERM INT
if module_loaded || [ -d /sys/module/pppoe_gro ]; then
    log "ERROR: module still present after a failed load. Keeping ${MARKER_FILE} so the next boot does not load it again."
else
    clear_own_marker
fi
exit 1
