#!/bin/sh
# memory-report.sh — Read-only memory + logging health snapshot for UniFi gateways.
#
# Usage (on the gateway):
#   ssh root@<gateway-ip> 'sh -s' < scripts/diagnostics/memory-report.sh
# Or copy and run locally:
#   scp scripts/diagnostics/memory-report.sh root@<gateway-ip>:/tmp/
#   ssh root@<gateway-ip> 'sh /tmp/memory-report.sh'
#
# Reports:
#   - RAM / swap totals
#   - Top 15 processes by RSS
#   - tmpfs usage (RAM-backed filesystems)
#   - journald storage mode + /run/log/journal size (volatile cap check)
#   - OOM events in dmesg
#   - UniFi Network JVM heap limits vs live RSS

set -u

hr() { printf '\n===== %s =====\n' "$1"; }

hr "HOST"
uname -a
uptime

hr "MEMORY"
free -m

hr "TOP 15 PROCESSES BY RSS (KB)"
ps -eo pid,rss,vsz,etime,comm,args --sort=-rss | head -16

hr "RSS TOTALS"
ps -eo rss --no-headers --sort=-rss | head -15 | \
    awk '{s+=$1} END {printf "Top 15 RSS sum : %d MB\n", s/1024}'
ps -eo rss --no-headers | \
    awk '{s+=$1} END {printf "All procs RSS  : %d MB (RSS double-counts shared libs)\n", s/1024}'

hr "TMPFS (RAM-backed filesystems)"
df -h -t tmpfs 2>/dev/null || df -h | grep -E '^tmpfs|/run|/tmp|/dev/shm'

hr "JOURNALD — STORAGE MODE + VOLATILE CAP"
grep -HE '^(Storage|RuntimeMaxUse|SystemMaxUse|MaxFileSec|ForwardToSyslog)' \
    /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null
echo
echo "/run/log/journal (tmpfs, volatile):"
du -sh /run/log/journal 2>/dev/null || echo "  (not present)"
echo "/var/log/journal (eMMC, persistent — should be stale if Storage=volatile):"
du -sh /var/log/journal 2>/dev/null || echo "  (not present)"
if [ -d /var/log/journal ]; then
    latest=$(ls -t /var/log/journal/*/*.journal 2>/dev/null | head -1)
    [ -n "$latest" ] && echo "  newest file mtime: $(stat -c '%y' "$latest")"
fi

hr "OOM EVENTS (dmesg)"
oom=$(dmesg -T 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -10)
if [ -z "$oom" ]; then
    echo "None."
else
    echo "$oom"
fi

hr "UNIFI NETWORK JVM (if running)"
jpid=$(pgrep -f 'unifi\.core\.enabled' 2>/dev/null | head -1)
if [ -n "${jpid:-}" ]; then
    echo "PID: $jpid"
    # Heap flags from cmdline
    tr '\0' '\n' < /proc/$jpid/cmdline | grep -E '^-Xm[sx]|ExitOnOutOfMemoryError|AlwaysPreTouch|UseG1GC'
    # Live memory
    grep -E '^(VmRSS|VmSize|VmSwap|VmPeak):' /proc/$jpid/status 2>/dev/null
else
    echo "No unifi Network JVM detected on this host."
fi

hr "SWAP ACTIVITY"
if command -v vmstat >/dev/null 2>&1; then
    # 2 samples, 1s apart — si/so columns show active paging
    vmstat 1 2 | awk 'NR==1||NR==2||NR==4'
else
    echo "(vmstat not available)"
fi

hr "DONE"
