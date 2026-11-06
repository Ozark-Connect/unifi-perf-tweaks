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
# WARNING: This targets eth6 / Port 7 (the 2nd SFP+ port) ONLY.
# For eth5 / Port 6, use 19-sfp-sgmiiplus-eth5.sh instead.
#
# Optional, for a PPPoE WAN on this port: touch /data/sfp-sgmiiplus/pppd-hup
# (all ports) or /data/sfp-sgmiiplus/pppd-hup-<iface> (this port only). The
# script then hangs up the PPPoE session's pppd with SIGHUP before switching,
# at most once per run. Some SFP sticks go silent for about a minute after the
# switch to 2.5G; without the hangup pppd only notices after its LCP echo
# timeout, and WAN failover cannot kick in until then. pppd must run with
# persist so it redials on its own. Without the file nothing changes.
#
# Target: UCG-Fiber / UXG-Fiber (IPQ9574, kernel 5.4.213-ui-ipq9574)
# Requires: qca-ssdk.ko loaded, module pre-deployed to /data/sfp-sgmiiplus/

SCRIPT_NAME="sfp-sgmiiplus"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
MODULE_DIR="/data/sfp-sgmiiplus"
MODULE_NAME="force_uniphy1_sgmiiplus"
MODULE_FILE="${MODULE_DIR}/${MODULE_NAME}.ko"
CLOCK_PATH="/sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate"
IFACE="eth6"
CARRIER_TIMEOUT=90
MAX_ATTEMPTS=5
HOLD_SECS=45

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Re-exec in background so on_boot.d doesn't block waiting for carrier
if [ "$1" != "--bg" ]; then
    nohup "$0" --bg >/dev/null 2>&1 &
    exit 0
fi

# ─── Optional pppd hangup (see header) ───

PPPD_HUP_FILE="${MODULE_DIR}/pppd-hup"
PPPD_HUP=0
if [ -e "${PPPD_HUP_FILE}" ] || [ -e "${PPPD_HUP_FILE}-${IFACE}" ]; then
    PPPD_HUP=1
    # One run per port at a time, so a second run cannot hang up a session the
    # first run already restored. The kernel drops the lock when the holder
    # exits. "command exec" keeps dash running if the open fails.
    RUN_LOCK_FILE="/run/${SCRIPT_NAME}.lock"
    if command -v flock >/dev/null 2>&1 && command exec 9>>"${RUN_LOCK_FILE}" 2>/dev/null; then
        flock -n 9
        rc=$?
        if [ $rc -eq 1 ]; then
            log "Another run is active (${RUN_LOCK_FILE} held). Nothing to do."
            exit 0
        elif [ $rc -ne 0 ]; then
            log "pppd hangup off: flock failed (exit ${rc})"
            PPPD_HUP=0
        fi
    else
        log "pppd hangup off: no flock or ${RUN_LOCK_FILE} not writable"
        PPPD_HUP=0
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

# ─── Optional pppd hangup: functions ───

PPP_PEERS_DIR="/etc/ppp/peers"
PPP_RUN_DIR="/run"
PPPOE_PROC="/proc/net/pppoe"
PROC_DIR="/proc"
PPP_IFACE=""
HUP_SENT=0
HUP_WAIT_SECS=10
HUP_BOOT_WAIT_SECS=60
hup_boot_waited=0

# Number of PPPoE sessions on ${IFACE} or one of its VLANs
pppoe_sessions() {
    if [ ! -r "${PPPOE_PROC}" ]; then
        echo 0
        return
    fi
    awk -v dev="${IFACE}" 'NR > 1 && ($3 == dev || index($3, dev ".") == 1) { n++ } END { print n + 0 }' "${PPPOE_PROC}"
}

# Prints the pppN whose peer file runs PPPoE on ${IFACE} or one of its VLANs
# (udapi writes "plugin rp-pppoe.so eth6.7"); prints nothing unless exactly one
ppp_iface_for_port() {
    name=""
    matches=0
    for f in "${PPP_PEERS_DIR}"/ppp[0-9]*; do
        [ -f "$f" ] || continue
        dev=$(awk '$1 == "plugin" && $2 ~ /pppoe/ { print $3; exit }' "$f" 2>/dev/null)
        case "$dev" in
            "${IFACE}"|"${IFACE}".*)
                name="${f##*/}"
                matches=$((matches + 1))
                ;;
        esac
    done
    [ "$matches" -eq 1 ] && echo "$name"
}

# True only for a clean positive count; any read or awk error counts as "no session"
pppoe_session_up() {
    n=$(pppoe_sessions 2>/dev/null) || return 1
    case "$n" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$n" -gt 0 ]
}

ppp_has_ipv4() {
    [ -n "${PPP_IFACE}" ] || return 1
    ip -4 -o addr show dev "${PPP_IFACE}" 2>/dev/null | grep -q " inet "
}

# Prints the PID of the one "pppd call ${PPP_IFACE}" process; nothing unless exactly one
pppd_pid() {
    found=""
    count=0
    for d in "${PROC_DIR}"/[0-9]*; do
        [ "$(cat "$d/comm" 2>/dev/null)" = "pppd" ] || continue
        cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$cmd" in
            *" call ${PPP_IFACE} "*|*" call ${PPP_IFACE}")
                found="${d##*/}"
                count=$((count + 1))
                ;;
        esac
    done
    [ "$count" -eq 1 ] && echo "$found"
}

# Checks that must hold right before the signal. Prints the reason for a skip,
# nothing when the hangup may go ahead. $1 = expected pppN.
pppd_hup_blocker() {
    if [ ! -e "${PPPD_HUP_FILE}" ] && [ ! -e "${PPPD_HUP_FILE}-${IFACE}" ]; then
        echo "${PPPD_HUP_FILE} was removed"
        return
    fi
    if [ "$(ppp_iface_for_port)" != "$1" ]; then
        echo "pppd peer for ${IFACE} changed or is ambiguous"
        return
    fi
    if ! pppoe_session_up || ! ppp_has_ipv4; then
        echo "no PPPoE session with IPv4 on ${IFACE} ($1)"
        return
    fi
    peer_file="${PPP_PEERS_DIR}/$1"
    if ! grep -qx 'persist' "$peer_file" 2>/dev/null || grep -qx 'nopersist' "$peer_file" 2>/dev/null; then
        echo "$peer_file has no persist, pppd would not redial"
        return
    fi
}

# Hangs up at most once per run; any failed check leaves pppd alone
pppd_hup_before_switch() {
    [ ${PPPD_HUP} -eq 1 ] || return 0
    [ ${HUP_SENT} -eq 0 ] || return 0

    PPP_IFACE=$(ppp_iface_for_port)
    if [ -z "${PPP_IFACE}" ]; then
        log "pppd hangup skipped: no single pppd peer runs PPPoE on ${IFACE}"
        return 0
    fi
    reason=$(pppd_hup_blocker "${PPP_IFACE}")
    if [ -n "$reason" ]; then
        log "pppd hangup skipped: $reason"
        return 0
    fi

    # Let the other on_boot.d scripts finish first; the wait budget is per run
    while [ "$(systemctl is-active udm-boot.service 2>/dev/null)" = "activating" ]; do
        if [ ${hup_boot_waited} -ge ${HUP_BOOT_WAIT_SECS} ]; then
            log "pppd hangup skipped: udm-boot still running after ${hup_boot_waited}s"
            return 0
        fi
        sleep 2
        hup_boot_waited=$((hup_boot_waited + 2))
    done

    # Check everything again after the wait (udapi may have rewritten the peer)
    pid=$(pppd_pid)
    if [ -z "$pid" ]; then
        log "pppd hangup skipped: not exactly one 'pppd call ${PPP_IFACE}' process"
        return 0
    fi
    reason=$(pppd_hup_blocker "${PPP_IFACE}")
    if [ -n "$reason" ]; then
        log "pppd hangup skipped: $reason"
        return 0
    fi
    pid_file="${PPP_RUN_DIR}/${PPP_IFACE}.pid"
    if [ "$(head -n 1 "$pid_file" 2>/dev/null)" != "$pid" ]; then
        log "pppd hangup skipped: $pid_file does not match pid ${pid}"
        return 0
    fi

    log "Sending SIGHUP to pppd pid ${pid} (${PPP_IFACE})"
    HUP_SENT=1
    if ! kill -HUP "$pid" 2>/dev/null; then
        log "WARNING: kill -HUP ${pid} failed; switching without hangup"
        return 0
    fi

    # Wait until the session is gone; never signal twice
    t=0
    while [ $t -lt $((HUP_WAIT_SECS * 2)) ]; do
        if ! pppoe_session_up && ! ppp_has_ipv4; then
            log "PPPoE session ended after $((t / 2)).$(( (t % 2) * 5 ))s"
            return 0
        fi
        sleep 0.5
        t=$((t + 1))
    done
    log "WARNING: PPPoE session still up ${HUP_WAIT_SECS}s after SIGHUP; switching anyway"
    return 0
}

# ─── Load and verify module ───

BEFORE_CLOCK=""
if [ -f "${CLOCK_PATH}" ]; then
    BEFORE_CLOCK=$(cat "${CLOCK_PATH}")
    log "Clock rate before: ${BEFORE_CLOCK} Hz"
fi

attempt=1
verified=0

while [ $attempt -le $MAX_ATTEMPTS ]; do
    pppd_hup_before_switch
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
    rmmod "${MODULE_NAME}" 2>> "${LOG_FILE}"
    RET=$?

    if [ ${RET} -ne 0 ]; then
        log "ERROR: rmmod failed with exit code ${RET}"
        exit 1
    fi

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

log "Done"
