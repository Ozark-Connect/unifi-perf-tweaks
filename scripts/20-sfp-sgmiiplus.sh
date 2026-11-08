#!/bin/sh
# 20-sfp-sgmiiplus.sh: Force 2nd SFP+ port (eth6 / Port 7) to SGMII+ 2.5G
#
# Waits for the SFP to establish a 1G link, then loads a kernel module that
# switches uniphy1 from SGMII 1G to SGMII+ 2.5G. The wait avoids a boot-order
# race with SFPs that need time to configure their SerDes (e.g., Zyxel PMG3000
# takes ~15s after boot to fire its 2.5G override). If no 1G link appears
# within the timeout, the module loads anyway — this handles SFPs that are
# hard-locked at 2.5G and can't establish a 1G link without the host matching.
#
# The boot-time mode set does not always commit: uniphy1 can stay at 125 MHz
# even though insmod succeeded, and early in boot a set that did commit can
# still be reverted up to ~35s later. Which boots are affected is timing-
# dependent, so a given firmware and SFP can boot cleanly and fail on the next
# try. The script retries up to five times, restoring stock SGMII 1G between
# attempts, and verifies that the 312.5 MHz clock holds for 45s before
# declaring success.
#
# The module bypasses the SSDK's SFP EEPROM validation by calling the uniphy
# mode set function directly. The SSDK's MAC sync polling loop re-reads the
# SFP EEPROM every ~12s and would revert the 2.5G change. The module (v3+)
# excludes eth6 from the polling loop's port bitmap and restarts it — the loop
# continues to run for all other ports, so eth5 link recovery is unaffected.
#
# Module v5 ignores the SFP auto-detect's link setting requests for eth6, so
# SGMII+ survives SFP re-plugs, SFP reboots and the fiber coming back. UniFi
# therefore no longer drops a non-2.5G SFP back to 1G while the module is
# loaded, so the script does it: success also needs the 2.5G SerDes link
# (module parameter pcs_link) within LINK_TIMEOUT, otherwise the module is
# removed and eth6 stays at stock SGMII 1G. After success the script keeps
# watching eth6. A different SFP, or no 2.5G link for LINK_TIMEOUT (also with
# an empty cage), removes the module and runs the load procedure again, at
# most MAX_RERUNS times per hour. Only one instance runs at a time. An SFP that only links at 1G is remembered
# and left at 1G until it is replaced. An empty cage is never taken over.
#
# WARNING: This targets eth6 / Port 7 (the 2nd SFP+ port) ONLY.
# For eth5 / Port 6, use 19-sfp-sgmiiplus-eth5.sh instead.
#
# Target: UCG-Fiber / UXG-Fiber (IPQ9574, kernel 5.4.213-ui-ipq9574)
# Requires: qca-ssdk.ko loaded, module pre-deployed to /data/sfp-sgmiiplus/

SCRIPT_NAME="sfp-sgmiiplus"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
MODULE_DIR="/data/sfp-sgmiiplus"
MODULE_NAME="force_uniphy1_sgmiiplus"
MODULE_FILE="${MODULE_DIR}/${MODULE_NAME}.ko"
CLOCK_PATH="/sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate"
PARAM_DIR="/sys/module/${MODULE_NAME}/parameters"
STATE_FILE="/run/${MODULE_NAME}.1g-sfp"
LOCK_FILE="/run/${MODULE_NAME}.loader.lock"
IFACE="eth6"
CARRIER_TIMEOUT=90
MAX_ATTEMPTS=5
HOLD_SECS=45
LINK_TIMEOUT=180
WATCH_INTERVAL=5
MAX_RERUNS=3

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Identity of the SFP in the cage: EEPROM A0h bytes 20-83 (vendor name, OUI,
# part number, revision, serial) as hex. Reads only these 64 bytes, never the
# diagnostics page. Empty if no SFP is present or the read fails.
sfp_id() {
    ethtool -m "${IFACE}" hex on offset 20 length 64 2>/dev/null | awk '
        /^0x/ { for (i = 2; i <= NF; i++) s = s $i }
        END { if (s ~ /^[0-9a-f]+$/ && s !~ /^(00)+$/ && s !~ /^(ff)+$/) print s }'
}

# Readable vendor name and part number for the log (A0h bytes 20-35, 40-55; the read length must be a multiple of 8)
sfp_name() {
    ethtool -m "${IFACE}" hex on offset 20 length 40 2>/dev/null | awk '
        BEGIN { for (i = 32; i < 127; i++) chr[sprintf("%02x", i)] = sprintf("%c", i) }
        /^0x/ { for (i = 2; i <= NF; i++) b[n++] = $i }
        END {
            for (i = 0; i < 36; i++) {
                c = (b[i] in chr) ? chr[b[i]] : " "
                if (i < 16) v = v c; else if (i >= 20) p = p c
            }
            gsub(/ +$/, "", v); gsub(/ +$/, "", p); print v " " p
        }'
}

# 1 = 2.5G SerDes link up, 0 = down or unreadable, empty = the module has no
# such parameter (pre-v5 module)
pcs_link() {
    [ -e "${PARAM_DIR}/pcs_link" ] || { echo ""; return; }
    v=$(cat "${PARAM_DIR}/pcs_link" 2>/dev/null)
    if [ "$v" = "1" ]; then echo 1; else echo 0; fi
}

# Wait up to LINK_TIMEOUT for the 2.5G link. Returns 0 on link, 2 if the
# module cannot report it, 1 on timeout.
wait_pcs_link() {
    waited=0
    while [ $waited -lt $LINK_TIMEOUT ]; do
        l=$(pcs_link)
        [ -z "$l" ] && return 2
        [ "$l" = "1" ] && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

remove_module() {
    rmmod "${MODULE_NAME}" 2>> "${LOG_FILE}"
    RET=$?
    if [ ${RET} -ne 0 ]; then
        log "ERROR: rmmod failed with exit code ${RET}"
        exit 1
    fi
}

# Stock 1G and no module: run the load procedure again when a different SFP
# is in the cage, or, if retry_secs is not 0, after retry_secs for the same
# SFP (an SFP that only links at 2.5G must not stay dead on stock 1G).
watch_for_new_sfp() {
    last="$1"
    retry_secs="$2"
    if [ "${retry_secs}" -gt 0 ]; then
        log "Watching ${IFACE}; trying 2.5G again in ${retry_secs}s or when the SFP is replaced"
    else
        log "Watching ${IFACE} for a different SFP"
    fi
    since=$(date +%s)
    while :; do
        sleep ${WATCH_INTERVAL}
        lsmod | grep -q "${MODULE_NAME}" && { log "Module was loaded by someone else; watcher stops"; exit 0; }
        now_id=$(sfp_id)
        if [ -n "${now_id}" ] && [ "${now_id}" != "${last}" ]; then
            log "SFP changed to $(sfp_name); running the load procedure"
            exec "$0" --rerun "${RERUN_TIMES}"
        fi
        if [ "${retry_secs}" -gt 0 ] && [ $(( $(date +%s) - since )) -ge "${retry_secs}" ]; then
            log "Retrying 2.5G after ${retry_secs}s"
            exec "$0" --rerun "${RERUN_TIMES}"
        fi
        [ -n "${now_id}" ] && last="${now_id}"
    done
}

# Re-exec in background so on_boot.d doesn't block waiting for carrier
case "$1" in
    --bg|--rerun) ;;
    *)
        nohup "$0" --bg >/dev/null 2>&1 &
        exit 0
        ;;
esac
RERUN_TIMES="$2"

# One instance at a time, also across the re-exec of the watcher: fd 8 stays
# open through exec, so a rerun keeps the lock it already holds.
if command -v flock >/dev/null 2>&1; then
    if [ "$1" != "--rerun" ] || ! { : >&8; } 2>/dev/null; then
        if ! { command exec 8>>"${LOCK_FILE}"; } 2>/dev/null; then
            log "WARNING: ${LOCK_FILE} not writable; running without the instance lock"
        fi
    fi
    if { : >&8; } 2>/dev/null && ! flock -n 8; then
        log "Another run is active (${LOCK_FILE} held). Nothing to do."
        exit 0
    fi
fi

# ─── Sanity checks ───

if [ ! -f "${MODULE_FILE}" ]; then
    log "ERROR: ${MODULE_FILE} not found. Deploy the module first — see docs/sfp-sgmiiplus.md"
    exit 1
fi

if lsmod | grep -q "${MODULE_NAME}"; then
    log "Module ${MODULE_NAME} already loaded. Nothing to do."
    exit 0
fi

if ! lsmod | grep -q "qca_ssdk"; then
    log "ERROR: qca-ssdk.ko not loaded. Cannot proceed."
    exit 1
fi

# The module carries no usable version field in modinfo, so look for a v5 string
if ! grep -q "config_aneg guard installed" "${MODULE_FILE}"; then
    log "ERROR: ${MODULE_FILE} is not the v5 module; this script needs v5"
    exit 1
fi

# ─── Never take over an empty cage ───

elapsed=0
SFP_ID=$(sfp_id)
while [ -z "${SFP_ID}" ] && [ $elapsed -lt $CARRIER_TIMEOUT ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    SFP_ID=$(sfp_id)
done
if [ -z "${SFP_ID}" ]; then
    log "No SFP detected in ${IFACE} after ${CARRIER_TIMEOUT}s; leaving stock SGMII 1G"
    watch_for_new_sfp "" 0
fi
log "SFP in ${IFACE}: $(sfp_name)"

if [ -f "${STATE_FILE}" ] && [ "$(cat "${STATE_FILE}")" = "${SFP_ID}" ]; then
    log "This SFP only linked at 1G since boot; leaving stock SGMII 1G (delete ${STATE_FILE} to try 2.5G again)"
    watch_for_new_sfp "${SFP_ID}" 0
fi

# ─── Wait for 1G carrier or timeout ───

elapsed=0
while [ $elapsed -lt $CARRIER_TIMEOUT ]; do
    carrier=$(cat /sys/class/net/${IFACE}/carrier 2>/dev/null)
    if [ "$carrier" = "1" ]; then
        log "${IFACE} has carrier after ${elapsed}s — loading module"
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

if [ "$carrier" != "1" ]; then
    log "${IFACE} no carrier after ${CARRIER_TIMEOUT}s — loading module anyway (SFP may be hard-locked at 2.5G)"
fi

if [ "$(sfp_id)" != "${SFP_ID}" ]; then
    log "SFP in ${IFACE} was removed or replaced while waiting; starting over"
    sleep ${WATCH_INTERVAL}
    exec "$0" --rerun "${RERUN_TIMES}"
fi

# ─── Load and verify module ───

BEFORE_CLOCK=""
if [ -f "${CLOCK_PATH}" ]; then
    BEFORE_CLOCK=$(cat "${CLOCK_PATH}")
    log "Clock rate before: ${BEFORE_CLOCK} Hz"
fi

attempt=1
verified=0

while [ $attempt -le $MAX_ATTEMPTS ]; do
    if [ "$(sfp_id)" != "${SFP_ID}" ]; then
        log "SFP in ${IFACE} was removed or replaced; starting over"
        sleep ${WATCH_INTERVAL}
        exec "$0" --rerun "${RERUN_TIMES}"
    fi
    log "Loading ${MODULE_NAME} (attempt ${attempt}/${MAX_ATTEMPTS})..."

    insmod "${MODULE_FILE}" 2>> "${LOG_FILE}"
    RET=$?

    if [ ${RET} -ne 0 ]; then
        log "ERROR: insmod failed with exit code ${RET}"
        exit 1
    fi

    # Give the mode set sequence time to complete (~300ms PLL relock + calibration)
    sleep 1

    if [ ! -f "${CLOCK_PATH}" ]; then
        log "WARNING: ${CLOCK_PATH} not found, cannot verify clock rate"
        verified=1
        break
    fi

    AFTER_CLOCK=$(cat "${CLOCK_PATH}")
    log "Clock rate after attempt ${attempt}: ${AFTER_CLOCK} Hz"

    # Clock is the success criterion, not carrier, so no-link 2.5G SFPs work.
    if [ "${AFTER_CLOCK}" = "312500000" ]; then
        log "Clock reached 312500000 Hz; verifying it holds for ${HOLD_SECS}s"
        held=0
        while [ $held -lt $HOLD_SECS ]; do
            sleep 5
            held=$((held + 5))
            AFTER_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null)
            if [ "${AFTER_CLOCK}" != "312500000" ]; then
                break
            fi
        done

        if [ "${AFTER_CLOCK}" = "312500000" ]; then
            log "Verified: uniphy1 running at 312.5 MHz (SGMII+ 2.5G) and held for ${HOLD_SECS}s"
            verified=1
            break
        fi

        log "WARNING: Attempt ${attempt} clock reverted to ${AFTER_CLOCK} Hz after ${held}s of holding"
    else
        log "WARNING: Attempt ${attempt} expected 312500000 Hz, got ${AFTER_CLOCK} Hz"
    fi

    log "Removing ${MODULE_NAME} to restore stock SGMII 1G before retry"
    remove_module

    elapsed=0
    carrier=""
    while [ $elapsed -lt 30 ]; do
        carrier=$(cat /sys/class/net/${IFACE}/carrier 2>/dev/null)
        if [ "$carrier" = "1" ]; then
            log "${IFACE} stock 1G carrier recovered after ${elapsed}s"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$carrier" != "1" ]; then
        log "WARNING: ${IFACE} stock 1G carrier did not recover after 30s; continuing anyway"
    fi

    if [ $attempt -lt $MAX_ATTEMPTS ]; then
        backoff=$((attempt * 5))
        log "Retrying after ${backoff}s backoff"
        sleep $backoff
    fi

    attempt=$((attempt + 1))
done

if [ $verified -ne 1 ]; then
    if lsmod | grep -q "${MODULE_NAME}"; then
        rmmod "${MODULE_NAME}" 2>> "${LOG_FILE}"
        RET=$?
        if [ ${RET} -ne 0 ]; then
            log "ERROR: final rmmod failed with exit code ${RET}"
            exit 1
        fi
    fi
    log "ERROR: 2.5G mode did not stick after ${MAX_ATTEMPTS} attempts; ${IFACE} was left in stock SGMII 1G state so the link still works at 1G"
    exit 1
fi

if lsmod | grep -q "${MODULE_NAME}"; then
    log "Module loaded successfully"
else
    log "ERROR: Module not present after insmod"
    exit 1
fi

# ─── v5: the SFP must actually link at 2.5G ───

wait_pcs_link
case $? in
    0)
        log "2.5G SerDes link up"
        # Data path check, log only: without fiber no frames arrive either,
        # so this must not fall back to 1G on its own.
        rx0=$(cat /sys/class/net/${IFACE}/statistics/rx_packets 2>/dev/null)
        sleep 30
        rx1=$(cat /sys/class/net/${IFACE}/statistics/rx_packets 2>/dev/null)
        if [ -n "$rx0" ] && [ -n "$rx1" ] && [ "$rx1" -gt "$rx0" ]; then
            log "Frames arriving on ${IFACE} ($((rx1 - rx0)) in 30s)"
        else
            log "WARNING: no frames received on ${IFACE} in 30s after the 2.5G link came up (no fiber/PON yet, or data path problem)"
        fi
        ;;
    2)
        log "ERROR: module reports no pcs_link (pre-v5 module?); removing it, ${IFACE} stays at stock SGMII 1G"
        remove_module
        exit 1
        ;;
    *)
        log "No 2.5G link within ${LINK_TIMEOUT}s; removing ${MODULE_NAME} to try stock SGMII 1G"
        remove_module
        elapsed=0
        carrier=""
        while [ $elapsed -lt 60 ]; do
            carrier=$(cat /sys/class/net/${IFACE}/carrier 2>/dev/null)
            [ "$carrier" = "1" ] && break
            sleep 2
            elapsed=$((elapsed + 2))
        done
        if [ "$carrier" = "1" ]; then
            echo "${SFP_ID}" > "${STATE_FILE}"
            log "${IFACE} links at stock 1G; leaving it there until this SFP is replaced or the gateway reboots"
            watch_for_new_sfp "${SFP_ID}" 0
        fi
        log "ERROR: no link at 2.5G or 1G; leaving stock SGMII 1G"
        watch_for_new_sfp "${SFP_ID}" 3600
        ;;
esac

log "Done; watching ${IFACE}"

# ─── v5: watch for SFP changes and lost 2.5G link ───

nolink=0
while :; do
    sleep ${WATCH_INTERVAL}
    lsmod | grep -q "${MODULE_NAME}" || { log "Module was removed; watcher stops"; exit 0; }

    now_id=$(sfp_id)
    reason=""
    if [ -n "${now_id}" ] && [ "${now_id}" != "${SFP_ID}" ]; then
        reason="SFP changed to $(sfp_name)"
    elif [ "$(pcs_link)" = "0" ]; then
        nolink=$((nolink + WATCH_INTERVAL))
        [ $nolink -ge $LINK_TIMEOUT ] && reason="no 2.5G link for ${LINK_TIMEOUT}s"
    else
        nolink=0
    fi
    [ -z "${reason}" ] && continue

    # Budget: at most MAX_RERUNS reruns per hour
    now=$(date +%s)
    recent=""
    for t in ${RERUN_TIMES}; do
        [ $((now - t)) -lt 3600 ] && recent="${recent} ${t}"
    done
    set -- ${recent}
    if [ $# -ge ${MAX_RERUNS} ]; then
        log "${reason}; rerun budget (${MAX_RERUNS}/h) used up, removing ${MODULE_NAME} and leaving stock SGMII 1G"
        remove_module
        # Watch from the SFP in the cage now, so a swap that used up the
        # budget does not start the load procedure again right away
        watch_for_new_sfp "${now_id:-${SFP_ID}}" 3600
    fi

    log "${reason}; removing ${MODULE_NAME} and running the load procedure again"
    remove_module
    exec "$0" --rerun "${recent} ${now}"
done
