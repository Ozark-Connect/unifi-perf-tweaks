#!/bin/sh
# 19-sfp-sgmiiplus-eth5.sh: set eth5 / Port 6 to SGMII+ 2.5G.
#
# Default: one-shot load with up to five clock retries and a 45s clock hold.
# Stock SFP auto-detection and recovery remain active; older modules work.
# Opt in to persistent hold with /data/sfp-sgmiiplus/hold (either port) or
# /data/sfp-sgmiiplus/hold-eth5. Hold requires a module exposing active hold
# and pcs_link parameters. It watches SFP identity and PCS, bounds recovery
# to three runs/hour, and leaves a stock-1G-capable SFP at 1G after fallback.
# Only one port may hold at a time. Hold flags are read at boot and the choice
# survives automatic recovery; changing them takes effect on the next boot.
# PPPoE WAN on this port: when exactly one pppd peer runs PPPoE on eth5 (or a
# VLAN on it) and its session is up, the loader hangs up that pppd with SIGHUP
# right before the switch, at most once per hour per port, so WAN failover
# does not wait for pppd's LCP echo timeout. pppd must run with persist so it
# redials on its own. Turn it off with /data/sfp-sgmiiplus/no-pppd-hup (all
# ports) or /data/sfp-sgmiiplus/no-pppd-hup-eth5. Without PPPoE on the port
# nothing changes.
# Target: UCG-Fiber / UXG-Fiber, kernel 5.4.213-ui-ipq9574.

SCRIPT_NAME="sfp-sgmiiplus-eth5"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
MODULE_DIR="/data/sfp-sgmiiplus"
MODULE_NAME="force_uniphy2_sgmiiplus"
MODULE_FILE="${MODULE_DIR}/${MODULE_NAME}.ko"
CLOCK_PATH="/sys/kernel/debug/clk/uniphy2_gcc_tx_clk/clk_rate"
PARAM_DIR="/sys/module/${MODULE_NAME}/parameters"
STATE_FILE="/run/${MODULE_NAME}.1g-sfp"
LOCK_FILE="/run/${MODULE_NAME}.loader.lock"
IFACE="eth5"
CARRIER_TIMEOUT=90
MAX_ATTEMPTS=5
HOLD_SECS=45
LINK_TIMEOUT=180
WATCH_INTERVAL=5
MAX_RERUNS=3
HOLD_MODE=0
if [ "$1" = "--rerun" ] && [ "$3" = "1" ]; then
    # Internal recovery retains the boot-time choice even if a flag is removed.
    HOLD_MODE=1
elif [ -e "${MODULE_DIR}/hold" ] || [ -e "${MODULE_DIR}/hold-${IFACE}" ]; then
    HOLD_MODE=1
fi

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
# such parameter
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
    since=$(monotonic_seconds) || { log "ERROR: cannot read monotonic time"; exit 1; }
    while :; do
        sleep ${WATCH_INTERVAL}
        lsmod | grep -q "${MODULE_NAME}" && { log "Module was loaded by someone else; watcher stops"; exit 0; }
        now_id=$(sfp_id)
        if [ -n "${now_id}" ] && [ "${now_id}" != "${last}" ]; then
            log "SFP changed to $(sfp_name); running the load procedure"
            exec "$0" --rerun "${RERUN_TIMES}" "${HOLD_MODE}"
        fi
        now=$(monotonic_seconds) || { log "ERROR: cannot read monotonic time"; exit 1; }
        if [ "${retry_secs}" -gt 0 ] && [ $((now - since)) -ge "${retry_secs}" ]; then
            log "Retrying 2.5G after ${retry_secs}s"
            exec "$0" --rerun "${RERUN_TIMES}" "${HOLD_MODE}"
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
RUN_MODE="$1"

# pppd hangup for a PPPoE WAN on this port (see header): on unless a
# no-pppd-hup flag exists. The blocker checks the flag again right before the
# signal, so setting it takes effect at once.
PPPD_HUP_OFF_FILE="${MODULE_DIR}/no-pppd-hup"
pppd_hup_off() {
    [ -e "${PPPD_HUP_OFF_FILE}" ] || [ -e "${PPPD_HUP_OFF_FILE}-${IFACE}" ]
}
PPPD_HUP=1
if pppd_hup_off; then
    PPPD_HUP=0
fi

# One instance at a time, also across the re-exec of the watcher: fd 8 stays
# open through exec, so a rerun keeps the lock it already holds. Returns 0
# with the lock held, 1 if flock did not get it (another run holds it;
# lock_error is set if flock failed for another reason), 2 with lock_error
# set if the lock cannot be used at all.
LOCK_HELD=0
take_lock() {
    lock_error=""
    [ ${LOCK_HELD} -eq 0 ] || return 0
    if ! command -v flock >/dev/null 2>&1; then
        lock_error="flock is required"
        return 2
    fi
    if [ "${RUN_MODE}" != "--rerun" ] || ! { : >&8; } 2>/dev/null; then
        if ! { command exec 8>>"${LOCK_FILE}"; } 2>/dev/null; then
            lock_error="${LOCK_FILE} not writable"
            return 2
        fi
    fi
    flock -n 8
    lock_rc=$?
    if [ ${lock_rc} -ne 0 ]; then
        [ ${lock_rc} -eq 1 ] || lock_error="flock failed (exit ${lock_rc})"
        return 1
    fi
    LOCK_HELD=1
    return 0
}

# Hold needs the lock from the start. Without hold only the pppd hangup uses
# it, and takes it right before the hangup, so two runs cannot hang up
# together and nothing changes for ports without PPPoE.
if [ "${HOLD_MODE}" -eq 1 ]; then
    take_lock
    case $? in
        1)
            log "Another run is active (${LOCK_FILE} held). Nothing to do."
            exit 0
            ;;
        2)
            log "ERROR: ${lock_error}; no module action taken"
            exit 1
            ;;
    esac
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

# Hold needs clock verification; the default keeps the legacy clock rules.
if [ "${HOLD_MODE}" -eq 1 ] && [ ! -r "${CLOCK_PATH}" ]; then
    log "ERROR: ${CLOCK_PATH} not readable; cannot verify 2.5G, no module action taken"
    exit 1
fi

# Monotonic seconds survive re-exec and are not affected by wall-clock changes.
monotonic_seconds() {
    read uptime ignored < /proc/uptime || return 1
    case "${uptime%%.*}" in
        ''|*[!0-9]*) return 1 ;;
        *) echo "${uptime%%.*}" ;;
    esac
}

# Every automatic entry shares this gate, including stock-1G watchers and
# SFP changes. One recovery run may still make MAX_ATTEMPTS load attempts.
admit_recovery() {
    [ "${RUN_MODE}" = "--rerun" ] || return 0
    now=$(monotonic_seconds) || { log "ERROR: cannot read monotonic time"; exit 1; }
    recent=""
    oldest=""
    for t in ${RERUN_TIMES}; do
        case "$t" in ''|*[!0-9]*) continue ;; esac
        if [ $((now - t)) -lt 3600 ]; then
            recent="${recent} ${t}"
            [ -n "${oldest}" ] || oldest="$t"
        fi
    done
    set -- ${recent}
    if [ $# -ge ${MAX_RERUNS} ]; then
        remaining=$((3600 - now + oldest))
        log "Recovery budget (${MAX_RERUNS}/h) used up; leaving stock SGMII 1G for ${remaining}s"
        sleep "${remaining}"
        exec "$0" --rerun "${recent}" "${HOLD_MODE}"
        exit 1
    fi
    RERUN_TIMES="${recent} ${now}"
}

# ─── Never take over an empty cage ───

if [ "${HOLD_MODE}" -eq 1 ]; then
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

if [ "${HOLD_MODE}" -eq 1 ] && [ "$(sfp_id)" != "${SFP_ID}" ]; then
    log "SFP in ${IFACE} was removed or replaced while waiting; starting over"
    sleep ${WATCH_INTERVAL}
    exec "$0" --rerun "${RERUN_TIMES}" "${HOLD_MODE}"
fi

# ─── pppd hangup: functions ───

PPP_PEERS_DIR="/etc/ppp/peers"
PPP_RUN_DIR="/run"
PPPOE_PROC="/proc/net/pppoe"
PROC_DIR="/proc"
HUP_STAMP_FILE="/run/${MODULE_NAME}.pppd-hup"
PPP_IFACE=""
HUP_SENT=0
HUP_CHECKED=0
hup_last_skip=""
HUP_WAIT_SECS=10
HUP_BOOT_WAIT_SECS=60
HUP_MIN_INTERVAL=3600
hup_boot_waited=0

# Number of PPPoE sessions on ${IFACE} or one of its VLANs
pppoe_sessions() {
    if [ ! -r "${PPPOE_PROC}" ]; then
        echo 0
        return
    fi
    awk -v dev="${IFACE}" 'NR > 1 && ($3 == dev || index($3, dev ".") == 1) { n++ } END { print n + 0 }' "${PPPOE_PROC}"
}

# Prints "<count> <pppN>" for the peer files that run PPPoE on ${IFACE} or one
# of its VLANs (udapi writes "plugin rp-pppoe.so eth5.7"); pppN is the last match
ppp_peers_on_port() {
    name=""
    matches=0
    for f in "${PPP_PEERS_DIR}"/ppp[0-9]*; do
        [ -f "$f" ] || continue
        case "${f##*/}" in ppp[0-9]|ppp[0-9][0-9]) ;; *) continue ;; esac
        dev=$(awk '$1 == "plugin" && $2 ~ /pppoe/ { print $3; exit }' "$f" 2>/dev/null)
        case "$dev" in
            "${IFACE}"|"${IFACE}".*)
                name="${f##*/}"
                matches=$((matches + 1))
                ;;
        esac
    done
    echo "${matches} ${name}"
}

# Prints the pppN of the one PPPoE peer on the port; nothing unless exactly one
ppp_iface_for_port() {
    set -- $(ppp_peers_on_port)
    [ "$1" = "1" ] && echo "$2"
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

# Logs why the hangup is skipped; the same reason is logged once per run
hup_skip() {
    [ "$1" != "${hup_last_skip}" ] || return 0
    hup_last_skip="$1"
    log "pppd hangup skipped: $1"
}

# Checks that must hold right before the signal. Prints the reason for a skip,
# nothing when the hangup may go ahead. $1 = expected pppN.
pppd_hup_blocker() {
    if pppd_hup_off; then
        echo "a no-pppd-hup flag is set"
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

# Hangs up at most once per run and once per HUP_MIN_INTERVAL per port, also
# across the re-exec of hold recovery (the time stamp lives in /run). A skipped
# hangup is tried again before the next load attempt of the same run. Any
# failed check leaves pppd alone. A port without a PPPoE peer is left alone
# without a log line.
pppd_hup_before_switch() {
    HUP_CHECKED=0
    [ ${PPPD_HUP} -eq 1 ] || return 0
    [ ${HUP_SENT} -eq 0 ] || return 0

    PPP_IFACE=$(ppp_iface_for_port)
    if [ -z "${PPP_IFACE}" ]; then
        set -- $(ppp_peers_on_port)
        [ "${1:-0}" -le 1 ] || hup_skip "$1 pppd peers run PPPoE on ${IFACE}"
        return 0
    fi
    reason=$(pppd_hup_blocker "${PPP_IFACE}")
    if [ -n "$reason" ]; then
        hup_skip "$reason"
        return 0
    fi

    # From here on the checks can take a while (boot wait, wait for the session to end)
    HUP_CHECKED=1
    take_lock
    case $? in
        1)
            if [ -n "${lock_error}" ]; then
                log "pppd hangup off: ${lock_error}"
                PPPD_HUP=0
            else
                hup_skip "another run is active (${LOCK_FILE} held)"
            fi
            return 0
            ;;
        2)
            log "pppd hangup off: ${lock_error}"
            PPPD_HUP=0
            return 0
            ;;
    esac

    # The time stamp is read under the lock, so two runs cannot both find it old
    hup_now=$(monotonic_seconds) || { hup_skip "cannot read monotonic time"; return 0; }
    hup_last=$(cat "${HUP_STAMP_FILE}" 2>/dev/null)
    case "${hup_last}" in
        ''|*[!0-9]*) ;;
        *)
            if [ $((hup_now - hup_last)) -lt ${HUP_MIN_INTERVAL} ]; then
                hup_skip "the last one was $((hup_now - hup_last))s ago (at most one per ${HUP_MIN_INTERVAL}s)"
                return 0
            fi
            ;;
    esac

    # Let the other on_boot.d scripts finish first; the wait budget is per run
    while [ "$(systemctl is-active udm-boot.service 2>/dev/null)" = "activating" ]; do
        if [ ${hup_boot_waited} -ge ${HUP_BOOT_WAIT_SECS} ]; then
            hup_skip "udm-boot still running after ${hup_boot_waited}s"
            return 0
        fi
        sleep 2
        hup_boot_waited=$((hup_boot_waited + 2))
    done

    # Check everything again after the wait (udapi may have rewritten the peer,
    # a run without the lock may have switched the port already)
    if lsmod | grep -q "${MODULE_NAME}"; then
        hup_skip "${MODULE_NAME} was loaded meanwhile"
        return 0
    fi
    pid=$(pppd_pid)
    if [ -z "$pid" ]; then
        hup_skip "not exactly one 'pppd call ${PPP_IFACE}' process"
        return 0
    fi
    reason=$(pppd_hup_blocker "${PPP_IFACE}")
    if [ -n "$reason" ]; then
        hup_skip "$reason"
        return 0
    fi
    pid_file="${PPP_RUN_DIR}/${PPP_IFACE}.pid"
    if [ "$(head -n 1 "$pid_file" 2>/dev/null)" != "$pid" ]; then
        hup_skip "$pid_file does not match pid ${pid}"
        return 0
    fi

    # The time stamp comes first: without it the hourly limit would not hold
    if ! { echo "${hup_now}" > "${HUP_STAMP_FILE}"; } 2>/dev/null; then
        hup_skip "cannot write ${HUP_STAMP_FILE}"
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
    while [ $t -lt ${HUP_WAIT_SECS} ]; do
        if ! pppoe_session_up && ! ppp_has_ipv4; then
            log "PPPoE session ended after ${t}s"
            return 0
        fi
        sleep 1
        t=$((t + 1))
    done
    log "WARNING: PPPoE session still up ${HUP_WAIT_SECS}s after SIGHUP; switching anyway"
    return 0
}

# ─── Load and verify module ───

[ "${HOLD_MODE}" -ne 1 ] || admit_recovery

BEFORE_CLOCK=""
if [ -f "${CLOCK_PATH}" ]; then
    BEFORE_CLOCK=$(cat "${CLOCK_PATH}")
    log "Clock rate before: ${BEFORE_CLOCK} Hz"
fi

attempt=1
verified=0

while [ $attempt -le $MAX_ATTEMPTS ]; do
    if [ "${HOLD_MODE}" -eq 1 ] && [ "$(sfp_id)" != "${SFP_ID}" ]; then
        log "SFP in ${IFACE} was removed or replaced; starting over"
        sleep ${WATCH_INTERVAL}
        exec "$0" --rerun "${RERUN_TIMES}" "${HOLD_MODE}"
    fi
    pppd_hup_before_switch
    if [ "${HOLD_MODE}" -eq 1 ] && [ ${HUP_CHECKED} -eq 1 ] && [ "$(sfp_id)" != "${SFP_ID}" ]; then
        # The hangup can take up to about 70s; never take over a cage that changed meanwhile
        log "SFP in ${IFACE} was removed or replaced; starting over"
        sleep ${WATCH_INTERVAL}
        exec "$0" --rerun "${RERUN_TIMES}" "${HOLD_MODE}"
    fi
    log "Loading ${MODULE_NAME} (attempt ${attempt}/${MAX_ATTEMPTS})..."

    if [ "${HOLD_MODE}" -eq 1 ]; then
        insmod "${MODULE_FILE}" hold=1 2>> "${LOG_FILE}"
    else
        insmod "${MODULE_FILE}" 2>> "${LOG_FILE}"
    fi
    RET=$?

    if [ ${RET} -ne 0 ]; then
        log "ERROR: insmod failed with exit code ${RET}"
        [ "${HOLD_MODE}" -ne 1 ] || log "ERROR: hold opt-in could not be loaded (unsupported parameter, busy hold owner, or module error); not retrying without hold"
        exit 1
    fi

    if [ "${HOLD_MODE}" -eq 1 ]; then
        hold_value=$(cat "${PARAM_DIR}/hold" 2>/dev/null)
        case "${hold_value}" in
            Y|1) hold_active=1 ;;
            *) hold_active=0 ;;
        esac
        if [ "${hold_active}" -ne 1 ] || [ ! -r "${PARAM_DIR}/pcs_link" ]; then
            log "ERROR: loaded module does not support active hold with pcs_link; loaded legacy module remains loaded to avoid an unsafe live unload"
            log "ERROR: replace the module with a matching hold-capable KO and perform a planned reboot; no watcher or retry started"
            exit 1
        fi
    fi

    # Give the mode set sequence time to complete (~300ms PLL relock + calibration)
    sleep 1

    if [ "${HOLD_MODE}" -eq 1 ]; then
        if [ ! -r "${CLOCK_PATH}" ] || ! AFTER_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null); then
            log "ERROR: ${CLOCK_PATH} unreadable; cannot verify clock rate"
            remove_module
            exit 1
        fi
    else
        if [ ! -f "${CLOCK_PATH}" ]; then
            log "WARNING: ${CLOCK_PATH} not found, cannot verify clock rate"
            verified=1
            break
        fi
        AFTER_CLOCK=$(cat "${CLOCK_PATH}")
    fi

    log "Clock rate after attempt ${attempt}: ${AFTER_CLOCK} Hz"

    # Clock is the success criterion, not carrier, so no-link 2.5G SFPs work.
    if [ "${AFTER_CLOCK}" = "312500000" ]; then
        log "Clock reached 312500000 Hz; verifying it holds for ${HOLD_SECS}s"
        held=0
        while [ $held -lt $HOLD_SECS ]; do
            sleep 5
            held=$((held + 5))
            if [ "${HOLD_MODE}" -eq 1 ]; then
                if [ ! -r "${CLOCK_PATH}" ] || ! AFTER_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null); then
                    log "ERROR: ${CLOCK_PATH} unreadable during hold; cannot verify clock rate"
                    remove_module
                    exit 1
                fi
            else
                AFTER_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null)
            fi
            if [ "${AFTER_CLOCK}" != "312500000" ]; then
                break
            fi
        done

        if [ "${AFTER_CLOCK}" = "312500000" ]; then
            log "Verified: uniphy2 running at 312.5 MHz (SGMII+ 2.5G) and held for ${HOLD_SECS}s"
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

if [ "${HOLD_MODE}" -ne 1 ]; then
    log "Done"
    exit 0
fi

# ─── Hold: the SFP must actually link at 2.5G ───

wait_pcs_link
case $? in
    0)
        log "2.5G SerDes link up"
        last_pcs_up=$(monotonic_seconds) || { log "ERROR: cannot read monotonic time"; remove_module; exit 1; }
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
        log "ERROR: module reports no pcs_link; removing it, ${IFACE} stays at stock SGMII 1G"
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

# ─── Hold: watch for SFP changes and lost 2.5G link ───

nolink=0
while :; do
    sleep ${WATCH_INTERVAL}
    lsmod | grep -q "${MODULE_NAME}" || { log "Module was removed; watcher stops"; exit 0; }

    now_id=$(sfp_id)
    reason=""
    new_sfp=0
    if [ -n "${now_id}" ] && [ "${now_id}" != "${SFP_ID}" ]; then
        log "SFP changed to $(sfp_name); watching its 2.5G link without reloading"
        SFP_ID="${now_id}"
        nolink=0
        # Start this SFP's timer at this observation, but retain the
        # overall outage timer so unstable EEPROM identities cannot defer recovery.
        new_sfp=1
    fi
    now=$(monotonic_seconds) || { log "ERROR: cannot read monotonic time"; remove_module; exit 1; }
    if [ "$(pcs_link)" = "0" ]; then
        nolink_total=$((now - last_pcs_up))
        [ $new_sfp -eq 1 ] || nolink=$((nolink + WATCH_INTERVAL))
        [ $nolink -ge $LINK_TIMEOUT ] && reason="no 2.5G link for ${LINK_TIMEOUT}s"
        [ $nolink_total -ge $((2 * LINK_TIMEOUT)) ] && reason="no 2.5G link for $((2 * LINK_TIMEOUT))s across SFP identities"
    else
        nolink=0
        last_pcs_up="${now}"
    fi
    [ -z "${reason}" ] && continue

    log "${reason}; removing ${MODULE_NAME} and running the load procedure again"
    remove_module
    exec "$0" --rerun "${RERUN_TIMES}" "${HOLD_MODE}"
done
