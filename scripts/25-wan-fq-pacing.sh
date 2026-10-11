#!/bin/sh
# Opt-in WAN socket pacing; independent of the SFP kernel-module loader.
# Deploy this file to /data/on_boot.d/ and the Python helper to HELPER below.
# Set INTERFACE here for boot-time selection, or pass --interface NAME manually.
# No speed setting, GSO change, kernel reload, polling, or automatic restart.

INTERFACE="ppp0"
UNIT="wan-fq-pacing.service"
HELPER="/data/wan-fq-pacing/wan-fq-pacing.py"
STATE_DIRECTORY="/run/wan-fq-pacing"
LOCK_FILE="/run/wan-fq-pacing-loader.lock"
MODE="start"
MODE_SET=0

fail() {
    printf '%s\n' "wan-fq-pacing: $*" >&2
    exit 1
}

usage() {
    printf '%s\n' "Usage: $0 [--stop | --status] [--interface NAME]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --stop|--status)
            [ "$MODE_SET" -eq 0 ] || fail "Choose only one mode."
            MODE=${1#--}
            MODE_SET=1
            shift
            ;;
        --interface)
            [ "$#" -ge 2 ] || fail "--interface requires a name."
            INTERFACE=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) fail "Unknown argument: $1 (use --help)." ;;
    esac
done

# Keep systemd's command/property parsing unambiguous for interface names.
case "$INTERFACE" in
    ''|[!a-zA-Z0-9_]*|*[!a-zA-Z0-9_.:-]*) fail "Interface must start with a letter, digit, or _ and contain only letters, digits, _, ., :, or -." ;;
esac
[ "${#INTERFACE}" -le 15 ] || fail "Interface name exceeds Linux's 15-character limit."

for prerequisite in python3 systemctl; do
    command -v "$prerequisite" >/dev/null 2>&1 || fail "Required command missing: $prerequisite."
done
PYTHON=$(command -v python3)
case "$PYTHON" in
    /*) ;;
    *) fail "python3 must resolve to an absolute executable path." ;;
esac
case "$PYTHON" in
    *[!a-zA-Z0-9_./-]*) fail "python3 executable path is unsafe for a systemd command property." ;;
esac
[ -r "$HELPER" ] || fail "Missing readable helper: $HELPER. Deploy scripts/wan-fq-pacing.py first."
[ -d /run/systemd/system ] || fail "A running systemd system manager is required."

read_unit() {
    UNIT_PROPERTIES=$(systemctl show "$UNIT" --no-pager \
        --property=LoadState --property=ActiveState --property=Transient \
        --property=Description --property=Type --property=Restart \
        --property=KillMode --property=TimeoutStopUSec \
        --property=ExecStart --property=ExecStopPost) || fail "Cannot query $UNIT."
    LOAD_STATE=""
    ACTIVE_STATE=""
    TRANSIENT=""
    DESCRIPTION=""
    SERVICE_TYPE=""
    RESTART=""
    KILL_MODE=""
    STOP_TIMEOUT=""
    EXEC_START=""
    EXEC_STOP_POST=""
    while IFS='=' read -r key value; do
        case "$key" in
            LoadState) LOAD_STATE=$value ;;
            ActiveState) ACTIVE_STATE=$value ;;
            Transient) TRANSIENT=$value ;;
            Description) DESCRIPTION=$value ;;
            Type) SERVICE_TYPE=$value ;;
            Restart) RESTART=$value ;;
            KillMode) KILL_MODE=$value ;;
            TimeoutStopUSec) STOP_TIMEOUT=$value ;;
            ExecStart) EXEC_START=$value ;;
            ExecStopPost) EXEC_STOP_POST=$value ;;
        esac
    done <<EOF
$UNIT_PROPERTIES
EOF
    [ -n "$LOAD_STATE" ] || fail "systemd returned no load state for $UNIT."
}

# systemctl includes runtime timestamps and exit status after ignore_errors.
# Match the entire stable command prefix and reject additional commands.
command_matches() {
    command_value=$1
    expected_prefix="{ path=$PYTHON ; argv[]=$PYTHON $HELPER $2 --interface $INTERFACE --state-directory $STATE_DIRECTORY ; ignore_errors=no ; "
    case "$command_value" in
        "$expected_prefix"*) ;;
        *) return 1 ;;
    esac
    command_suffix=${command_value#"$expected_prefix"}
    case "$command_suffix" in
        *'{'*|*'argv[]='*) return 1 ;;
        *' }') return 0 ;;
        *) return 1 ;;
    esac
}

require_matching_unit() {
    [ "$LOAD_STATE" = "loaded" ] &&
    [ "$TRANSIENT" = "yes" ] &&
    [ "$DESCRIPTION" = "WAN fq pacing managed watcher ($INTERFACE)" ] &&
    [ "$SERVICE_TYPE" = "exec" ] &&
    [ "$RESTART" = "no" ] &&
    [ "$KILL_MODE" = "control-group" ] &&
    [ "$STOP_TIMEOUT" = "15s" ] &&
    command_matches "$EXEC_START" --watch &&
    command_matches "$EXEC_STOP_POST" --restore ||
        fail "$UNIT has unexpected configuration or a different interface; refusing to start or stop it. Inspect systemctl show $UNIT and stop the original configuration first."
}

if [ "$MODE" = "status" ]; then
    read_unit
    printf '%s\n' "$UNIT_PROPERTIES"
    "$PYTHON" "$HELPER" --status --interface "$INTERFACE" --state-directory "$STATE_DIRECTORY"
    exit $?
fi

[ "$(id -u)" -eq 0 ] || fail "Root is required to start or stop WAN pacing."
command -v flock >/dev/null 2>&1 || fail "Required command missing: flock."
if [ "$MODE" = "start" ]; then
    command -v systemd-run >/dev/null 2>&1 || fail "Required command missing: systemd-run."
    command -v tc >/dev/null 2>&1 || fail "Required command missing: tc (iproute2)."
fi

# Serialize this loader's starts and stops; the systemd unit name also prevents
# a second watcher if another launcher races outside this lock.
exec 9>"$LOCK_FILE" || fail "Cannot open loader lock: $LOCK_FILE."
flock -w 15 9 || fail "Another loader invocation still holds $LOCK_FILE."
read_unit

if [ "$LOAD_STATE" != "not-found" ]; then
    require_matching_unit
fi

if [ "$MODE" = "stop" ]; then
    if [ "$LOAD_STATE" != "not-found" ]; then
        systemctl stop "$UNIT" || fail "Stopping $UNIT failed; refusing to restore while it may still be running."
    fi
    # ExecStopPost normally restores; repeat safely for an absent/crashed unit.
    "$PYTHON" "$HELPER" --restore --interface "$INTERFACE" --state-directory "$STATE_DIRECTORY"
    exit $?
fi

if [ "$LOAD_STATE" != "not-found" ]; then
    case "$ACTIVE_STATE" in
        active|activating) exit 0 ;;
        inactive|failed)
            # Only an explicit invocation restarts a previously stopped watcher.
            systemctl start "$UNIT" || fail "Starting the existing $UNIT failed."
            exit 0
            ;;
        *) fail "$UNIT is $ACTIVE_STATE; wait for its current transition before starting."
    esac
fi

# Type=exec returns once Python is executed, not when the long-lived watch ends.
# ExecStopPost also runs after a watcher crash; no Restart policy is installed.
systemd-run --unit="$UNIT" \
    --description="WAN fq pacing managed watcher ($INTERFACE)" \
    --property=Type=exec --property=Restart=no \
    --property=KillMode=control-group --property=TimeoutStopSec=15s \
    --property="ExecStopPost=$PYTHON $HELPER --restore --interface $INTERFACE --state-directory $STATE_DIRECTORY" \
    "$PYTHON" "$HELPER" --watch --interface "$INTERFACE" --state-directory "$STATE_DIRECTORY" ||
    fail "Cannot create $UNIT; an existing or concurrently created unit is never replaced."
