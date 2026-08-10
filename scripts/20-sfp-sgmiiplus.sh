#!/bin/sh
# 20-sfp-sgmiiplus.sh: Force 2nd SFP+ port (eth6 / Port 7) to SGMII+ 2.5G
#
# Loads the kernel module as soon as qca_ssdk is available. The module forces
# uniphy1 from SGMII 1G to SGMII+ 2.5G, excludes eth6 from the SSDK MAC-sync
# bitmap, and continuously verifies the physical UniPHY mode. If a later SFP
# event restores native SGMII, the module disables the data path, reasserts
# SGMII+, and resynchronizes PCS and MAC state.
#
# A runtime-directory lock prevents duplicate background instances. The module
# is loaded exactly once: this script never unloads or retries a live module.
# The self-healing monitor owns recovery after a successful insmod.
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
LOCK_DIR="/run/${SCRIPT_NAME}.lock"
QCA_SSDK_TIMEOUT=90
VERIFY_TIMEOUT=60
VERIFY_HOLD_SECS=15

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Re-exec in background so on_boot.d doesn't block qca_ssdk wait or verification
if [ "$1" != "--bg" ]; then
    nohup "$0" --bg >/dev/null 2>&1 &
    exit 0
fi

# ─── Single-instance guard ───

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    log "Another ${SCRIPT_NAME} loader is already active. Nothing to do."
    exit 0
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT INT TERM

# ─── Sanity checks ───

if [ ! -f "${MODULE_FILE}" ]; then
    log "ERROR: ${MODULE_FILE} not found. Deploy the module first — see docs/sfp-sgmiiplus.md"
    exit 1
fi

elapsed=0
while [ ${elapsed} -lt ${QCA_SSDK_TIMEOUT} ]; do
    if lsmod | grep -q "^qca_ssdk "; then
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

if ! lsmod | grep -q "^qca_ssdk "; then
    log "ERROR: qca_ssdk did not load within ${QCA_SSDK_TIMEOUT}s"
    exit 1
fi

if lsmod | grep -q "^${MODULE_NAME} "; then
    log "Module ${MODULE_NAME} already loaded. Nothing to do."
    exit 0
fi

# ─── Load once; the module owns recovery ───

if [ -f "${CLOCK_PATH}" ]; then
    BEFORE_CLOCK=$(cat "${CLOCK_PATH}")
    log "Clock rate before: ${BEFORE_CLOCK} Hz"
fi

log "Loading ${MODULE_NAME}..."
insmod "${MODULE_FILE}" 2>> "${LOG_FILE}"
RET=$?

if [ ${RET} -ne 0 ]; then
    log "ERROR: insmod failed with exit code ${RET}"
    exit 1
fi

if ! lsmod | grep -q "^${MODULE_NAME} "; then
    log "ERROR: Module not present after successful insmod"
    exit 1
fi

if [ ! -f "${CLOCK_PATH}" ]; then
    log "WARNING: ${CLOCK_PATH} not found; module is loaded but clock rate cannot be verified"
    log "Module loaded successfully"
    log "Done"
    exit 0
fi

elapsed=0
held=0
verified=0
while [ ${elapsed} -lt ${VERIFY_TIMEOUT} ]; do
    AFTER_CLOCK=$(cat "${CLOCK_PATH}" 2>/dev/null)
    if [ "${AFTER_CLOCK}" = "312500000" ]; then
        held=$((held + 1))
        if [ ${held} -ge ${VERIFY_HOLD_SECS} ]; then
            verified=1
            break
        fi
    else
        held=0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
done

if [ ${verified} -eq 1 ]; then
    log "Verified: uniphy1 held at 312.5 MHz (SGMII+ 2.5G) for ${VERIFY_HOLD_SECS}s"
else
    log "ERROR: uniphy1 did not hold 312.5 MHz for ${VERIFY_HOLD_SECS}s within ${VERIFY_TIMEOUT}s"
    log "Module remains loaded; automatic unload is intentionally disabled"
    exit 1
fi

log "Module loaded successfully"
log "Done"
