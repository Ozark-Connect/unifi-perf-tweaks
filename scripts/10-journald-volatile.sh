#!/bin/bash
# 10-journald-volatile.sh: Move journald to RAM, disable syslog forwarding
#
# Eliminates eMMC writes from system logging. Logs survive until reboot
# but never touch eMMC flash. Reduces eMMC write pressure by ~60-70%.
#
# Trade-off: You lose logs on reboot. If you need log persistence across
# reboots, don't use this script - consider forwarding to a remote syslog
# server instead.
#
# Compatible with all UniFi Cloud Gateway models.

LOG_TAG="journald-volatile"
JOURNALD_CONF="/etc/systemd/journald.conf"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
}

# Check current state
CURRENT_STORAGE=$(grep "^Storage=" "$JOURNALD_CONF" 2>/dev/null | cut -d= -f2)
CURRENT_SYSLOG=$(grep "^ForwardToSyslog=" "$JOURNALD_CONF" 2>/dev/null | cut -d= -f2)

if [ "$CURRENT_STORAGE" = "volatile" ] && [ "$CURRENT_SYSLOG" = "no" ]; then
    log "Already configured. Nothing to do."
    exit 0
fi

CHANGED=false

if [ "$CURRENT_STORAGE" != "volatile" ]; then
    sed -i 's/^Storage=.*/Storage=volatile/' "$JOURNALD_CONF"
    log "Changed Storage=$CURRENT_STORAGE -> volatile"
    CHANGED=true
fi

if [ "$CURRENT_SYSLOG" != "no" ]; then
    sed -i 's/^ForwardToSyslog=.*/ForwardToSyslog=no/' "$JOURNALD_CONF"
    log "Changed ForwardToSyslog=$CURRENT_SYSLOG -> no"
    CHANGED=true
fi

if [ "$CHANGED" = true ]; then
    systemctl restart systemd-journald
    log "journald restarted. Logs now in RAM only (/run/log/journal/)."
fi
