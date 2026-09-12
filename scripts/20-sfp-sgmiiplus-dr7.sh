#!/bin/sh
SCRIPT_NAME="sfp-sgmiiplus"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
MODULE_DIR="/data/sfp-sgmiiplus"
MODULE_NAME="force_uniphy1_sgmiiplus_dr7"
MODULE_FILE="${MODULE_DIR}/${MODULE_NAME}.ko"
CLOCK_PATH="/sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate"
IFACE="eth4"
CARRIER_TIMEOUT=90

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

if [ "$1" != "--bg" ]; then
    nohup "$0" --bg >/dev/null 2>&1 &
    exit 0
fi

if [ ! -f "${MODULE_FILE}" ]; then
    log "ERROR: ${MODULE_FILE} not found"
    exit 1
fi
if lsmod | grep -q "${MODULE_NAME}"; then
    log "Module already loaded"
    exit 0
fi
if ! lsmod | grep -q "qca_ssdk"; then
    log "ERROR: qca-ssdk not loaded"
    exit 1
fi

elapsed=0
while [ $elapsed -lt $CARRIER_TIMEOUT ]; do
    carrier=$(cat /sys/class/net/${IFACE}/carrier 2>/dev/null)
    if [ "$carrier" = "1" ]; then
        log "${IFACE} has carrier after ${elapsed}s"
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

if [ "$carrier" != "1" ]; then
    log "${IFACE} no carrier after ${CARRIER_TIMEOUT}s - loading anyway"
fi

BEFORE_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null)
log "Clock before: ${BEFORE_CLOCK} Hz"

insmod "${MODULE_FILE}" 2>> "${LOG_FILE}"
RET=$?
if [ ${RET} -ne 0 ]; then
    log "ERROR: insmod failed (${RET})"
    exit 1
fi

sleep 1
AFTER_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null)
log "Clock after: ${AFTER_CLOCK} Hz"

if [ "${AFTER_CLOCK}" = "312500000" ]; then
    log "Verified: 312.5 MHz (SGMII+ 2.5G) - OK"
else
    log "WARNING: Expected 312500000, got ${AFTER_CLOCK}"
fi

log "Done"
