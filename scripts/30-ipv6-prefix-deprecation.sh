#!/bin/bash
# 30-ipv6-prefix-deprecation.sh: Deprecate stale delegated IPv6 prefixes on the LAN
#
# UniFi OS restarts dnsmasq whenever the delegated prefix (DHCPv6-PD) changes, for
# example on every PPPoE reconnect with ISPs that hand out a new prefix each time.
# The new dnsmasq never advertises the old /64 with lifetime 0, so LAN clients keep
# it preferred for up to its preferred lifetime and new connections from those
# addresses time out (RFC 7084 L-13, RFC 9096).
#
# This installs a small Python daemon (standard library only) as a systemd service.
# It watches the dynamic /64s on every network dnsmasq serves with SLAAC, and once a
# network carries a new prefix it sends Router Advertisements that advertise each
# vanished prefix with valid and preferred lifetime 0 and withdraw the gateway's old
# addresses as DNS servers. Clients stop using the old prefix within seconds.
# It never changes addresses, routes, or the UniFi dnsmasq configuration.
#
# Files: /data/ipv6-prefix-deprecation/ (daemon, prefix history),
#        /etc/systemd/system/ipv6-prefix-deprecation.service (recreated at boot),
#        /run/ipv6-prefix-deprecation/status.json (status, RAM only).
#
# Temporary workaround until UniFi OS deprecates old prefixes itself.

LOG_TAG="ipv6-prefix-deprecation"
DIR="/data/ipv6-prefix-deprecation"
DAEMON="$DIR/ipv6-prefix-deprecation.py"
UNIT="/etc/systemd/system/ipv6-prefix-deprecation.service"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
}

if ! command -v python3 >/dev/null 2>&1; then
    log "python3 not found, not installing."
    exit 1
fi

mkdir -p "$DIR" || { log "Creating $DIR failed."; exit 1; }
chmod 700 "$DIR"

# Writes stdin to $1 (mode $2) only when the content differs, so a reboot writes nothing to
# the eMMC: the comparison copy lives on tmpfs. Prints "changed" when it wrote; fails without
# touching $1 when any step fails.
install_if_changed() {
    local target="$1" mode="$2" tmp
    tmp=$(mktemp /run/ipv6-prefix-deprecation-install.XXXXXX) || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 0
    fi
    if install -m "$mode" "$tmp" "$target.new" && mv -f "$target.new" "$target"; then
        rm -f "$tmp"
        echo "changed"
        return 0
    fi
    rm -f "$tmp" "$target.new"
    return 1
}

if ! DAEMON_CHANGED=$(install_if_changed "$DAEMON" 700 <<'PYEOF'
#!/usr/bin/env python3
"""ipv6-prefix-deprecation: deprecates stale delegated LAN prefixes after a PD change.

UniFi OS restarts dnsmasq whenever the delegated prefix changes, so dnsmasq's own
deprecation of a vanished prefix never runs and clients keep the old /64 preferred
until its preferred lifetime runs out (RFC 7084 L-13, RFC 9096). This daemon
remembers the dynamic /64s on every bridge dnsmasq serves with constructor:<br>,ra-only
and, once a bridge carries a new prefix, sends unsolicited RAs from the bridge's
link-local address that advertise each vanished prefix with valid and preferred
lifetime 0 (RFC 9096 section 3.5) and withdraw the router's old addresses as RDNSS.
It never touches addresses, routes or dnsmasq.

Usage: ipv6-prefix-deprecation.py [--dry-run]   (--dry-run logs instead of sending, keeps no state)
"""
import fcntl
import ipaddress
import json
import os
import random
import socket
import struct
import subprocess
import sys
import time
import glob

STATE_FILE = "/data/ipv6-prefix-deprecation/state.json"
RUN_DIR = "/run/ipv6-prefix-deprecation"
STATUS_FILE = RUN_DIR + "/status.json"
LOCK_FILE = RUN_DIR + "/lock"
DNSMASQ_GLOB = "/run/dnsmasq.dhcp.conf.d/*.conf"
STATE_VERSION = 1

POLL_S = 3
# Three initial advertisements (RFC 4861 MAX_INITIAL_RTR_ADVERTISEMENTS), then repeat.
BURST_OFFSETS_S = (0, 4, 16)
REPEAT_S = 120
REPEAT_JITTER_S = 10
MIN_GAP_S = 3  # RFC 4861 MIN_DELAY_BETWEEN_RAS
# RFC 9096: keep deprecating for the previously advertised valid lifetime. Clients clamp
# a received valid lifetime to 2 h (RFC 4862 5.5.3e), so never stop earlier than that.
MIN_DEPRECATE_S = 7200
MAX_DEPRECATE_S = 86400
MAX_STALE_PER_BRIDGE = 8
CONFIRM_SNAPSHOTS = 2
# A renewal only extends the stored expiry on disk when it grows by more than this (eMMC).
EXPIRY_WRITE_STEP_S = 3600
STATUS_HEARTBEAT_S = 30
CMD_TIMEOUT_S = 5
# A wall clock step beyond this between two polls (NTP after boot) shifts all stored times.
CLOCK_STEP_S = 60
ERROR_REPORT_POLLS = 2
INFINITE = 0xFFFFFFFF
GUA = ipaddress.ip_network("2000::/3")


def log(msg):
    print(msg, flush=True)


def parse_dnsmasq(text):
    """Bridges with a constructor:<br>,ra-only range and a complete ra-param.

    Returns ({bridge: {"prf": str, "rl": int}}, [skip reasons]). Only lines that start with
    the option name count, so commented-out options never match.
    """
    ranges = set()
    other_modes = set()
    params = {}
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("dhcp-range="):
            toks = line[len("dhcp-range="):].split(",")
            for i, tok in enumerate(toks):
                if tok.startswith("constructor:"):
                    br = tok[len("constructor:"):]
                    if not br or "*" in br:
                        continue
                    if "ra-only" in toks[i + 1:]:
                        ranges.add(br)
                    else:
                        other_modes.add(br)
        elif line.startswith("ra-param="):
            toks = line[len("ra-param="):].split(",")
            rest = [t for t in toks[1:] if not t.startswith("mtu:")]
            prf = "medium"
            if rest and rest[0] in ("high", "medium", "low"):
                prf = rest.pop(0)
            if len(rest) == 2 and all(t.isdigit() for t in rest):
                params[toks[0]] = {"prf": prf, "rl": int(rest[1])}
    bridges, skipped = {}, []
    for br in sorted(ranges):
        p = params.get(br)
        if p is None:
            skipped.append(f"{br}: no ra-param with router lifetime")
        elif not 60 <= p["rl"] <= 9000:
            skipped.append(f"{br}: router lifetime {p['rl']} out of range")
        else:
            bridges[br] = p
    for br in sorted(other_modes - ranges):
        skipped.append(f"{br}: RA mode other than ra-only")
    return bridges, skipped


def parse_addrs(links, bridges):
    """Dynamic global /64s per bridge from `ip -j -6 addr show`, and every global /64 present.

    Returns ({bridge: {prefix: {"valid": s, "addrs": [addr, ...]}}}, {prefix, ...}). A watched
    bridge without a global address maps to {}; a bridge missing from the output is missing
    from the result, so callers can tell "no prefix" from "not visible". The present set holds
    the /64 of every global address on any interface, static or deprecated ones included:
    a prefix in it is never advertised as stale.
    """
    snap, present = {}, set()
    for link in links:
        dev = link.get("ifname")
        for a in link.get("addr_info", []):
            if a.get("family") == "inet6" and "local" in a and a.get("scope") == "global":
                present.add(str(ipaddress.ip_network(f"{a['local']}/64", strict=False)))
        if dev not in bridges:
            continue
        prefixes = snap.setdefault(dev, {})
        for a in link.get("addr_info", []):
            if a.get("family") != "inet6" or "local" not in a or a.get("scope") != "global":
                continue
            if a.get("prefixlen") != 64:
                continue
            if a.get("tentative") or a.get("dadfailed") or a.get("deprecated"):
                continue
            valid = a.get("valid_life_time")
            if not isinstance(valid, int) or valid <= 0 or valid >= INFINITE:
                continue  # static or permanent address, not delegated
            net = ipaddress.ip_network(f"{a['local']}/64", strict=False)
            if not net.subnet_of(GUA):
                continue
            entry = prefixes.setdefault(str(net), {"valid": 0, "addrs": []})
            entry["valid"] = max(entry["valid"], valid)
            entry["addrs"].append(str(ipaddress.ip_address(a["local"])))
    return snap, present


def has_default_route(routes):
    """True when `ip -j -6 route show table all default` lists a usable default route."""
    return any(r.get("dst") == "default" and r.get("type", "unicast") == "unicast" for r in routes)


def drop_present(due, present):
    """Removes prefixes that are present again (and their RDNSS addresses) from a send list."""
    out = {}
    for br, (prefixes, rdnss) in due.items():
        keep = [p for p in prefixes if p not in present]
        if keep:
            nets = [ipaddress.ip_network(p) for p in keep]
            out[br] = (keep, [a for a in rdnss if any(ipaddress.ip_address(a) in n for n in nets)])
    return out


def build_ra(prf, router_lifetime, mac, prefixes, rdnss):
    """RA with one PIO (L+A, valid 0, preferred 0) per prefix, RDNSS lifetime 0, SLLA."""
    if not 60 <= router_lifetime <= 9000:
        raise ValueError(f"router lifetime {router_lifetime} refused")
    prf_bits = {"high": 0x08, "medium": 0x00, "low": 0x18}[prf]
    # Type 134, code 0, checksum (kernel), cur hop limit 0 (unspecified), M/O 0
    pkt = struct.pack("!BBHBBHII", 134, 0, 0, 0, prf_bits, router_lifetime, 0, 0)
    for p in prefixes:
        net = ipaddress.ip_network(p)
        pkt += struct.pack("!BBBBIII", 3, 4, 64, 0xC0, 0, 0, 0) + net.network_address.packed
    if rdnss:
        pkt += struct.pack("!BBHI", 25, 1 + 2 * len(rdnss), 0, 0)
        for a in rdnss:
            pkt += ipaddress.ip_address(a).packed
    pkt += struct.pack("!BB", 1, 1) + mac
    return pkt


def clamp_until(expires, now):
    return min(max(expires, now + MIN_DEPRECATE_S), now + MAX_DEPRECATE_S)


class Tracker:
    """Prefix state per bridge. Persisted: current and stale prefixes. Not persisted: timers."""

    def __init__(self, state=None):
        self.bridges = {}
        if state and state.get("version") == STATE_VERSION:
            for br, st in state.get("bridges", {}).items():
                self.bridges[br] = {"current": dict(st.get("current", {})),
                                    "stale": dict(st.get("stale", {}))}
        self.dirty = False
        self.missing = {}   # (bridge, prefix) -> consecutive snapshots without it
        self.schedule = {}  # bridge -> {"start": mono, "n": sends, "next": mono}
        self.last_send = {}
        self.events = []
        self.clock = None   # (wall, mono) of the previous update
        self.touched = set()  # (bridge, prefix) whose times this process set since the last clock step
        self.mark_saved()

    def mark_saved(self):
        """Records the expiries now on disk, so renewals are written only in coarse steps."""
        self.saved_expires = {(br, p): c["expires"] for br, st in self.bridges.items()
                              for p, c in st["current"].items()}

    def to_state(self):
        return {"version": STATE_VERSION, "bridges": self.bridges}

    def _event(self, msg):
        self.events.append(msg)
        log(msg)

    def _follow_clock(self, now, mono):
        """Shifts the times this process derived from a wrong clock by a clock step, so an NTP
        correction after boot neither ends nor stretches a deprecation. Times loaded from disk
        were taken under a correct clock and stay. After a step every time is in the corrected
        clock, so a later step shifts all of them."""
        if self.clock is not None:
            step = (now - self.clock[0]) - (mono - self.clock[1])
            if abs(step) > CLOCK_STEP_S:
                for br, p in self.touched:
                    st = self.bridges.get(br, {})
                    if p in st.get("current", {}):
                        st["current"][p]["expires"] = int(st["current"][p]["expires"] + step)
                        if (br, p) in self.saved_expires:
                            self.saved_expires[(br, p)] = int(self.saved_expires[(br, p)] + step)
                    if p in st.get("stale", {}):
                        st["stale"][p]["until"] = int(st["stale"][p]["until"] + step)
                self.touched = {(br, p) for br, st in self.bridges.items()
                                for part in ("current", "stale") for p in st[part]}
                self.dirty = True
                log(f"wall clock stepped by {step:+.0f} s, times derived since then shifted")
        self.clock = (now, mono)

    def lost_sight(self, br=None):
        """A bridge (or, with None, everything) could not be observed: losses start over."""
        for key in [k for k in self.missing if br is None or k[0] == br]:
            del self.missing[key]

    def update(self, bridges, snap, present, now, mono):
        """Applies one snapshot. Returns {bridge: (prefixes, rdnss)} due to be sent now."""
        self._follow_clock(now, mono)
        for br in {k[0] for k in self.missing} - set(bridges):
            self.lost_sight(br)  # bridge not configured right now: no decision
        for br in bridges:
            cur = snap.get(br)
            if cur is None:
                self.lost_sight(br)
                continue  # bridge not visible: no decision
            st = self.bridges.setdefault(br, {"current": {}, "stale": {}})
            if not cur:
                for p in st["current"]:
                    self.missing.pop((br, p), None)
                continue  # no prefix at all (WAN down): wait for a new one
            for p, info in cur.items():
                exp = int(now + info["valid"])
                old = st["current"].get(p)
                if old is None:
                    st["current"][p] = {"expires": exp, "addrs": sorted(info["addrs"])}
                    self.touched.add((br, p))
                    self.dirty = True
                elif exp > old["expires"]:
                    old["expires"] = exp
                    self.touched.add((br, p))
                    if exp - self.saved_expires.get((br, p), 0) > EXPIRY_WRITE_STEP_S:
                        self.dirty = True
                if old is not None and sorted(info["addrs"]) != old["addrs"]:
                    old["addrs"] = sorted(info["addrs"])
                    self.dirty = True
            for p in [p for p in st["stale"] if p in present]:
                del st["stale"][p]
                self.dirty = True
                self._event(f"{br}: {p} is back, no longer deprecated")
            confirmed = []
            for p in list(st["current"]):
                if p in cur:
                    self.missing.pop((br, p), None)
                    continue
                n = self.missing.get((br, p), 0) + 1
                self.missing[(br, p)] = n
                if n >= CONFIRM_SNAPSHOTS:
                    del self.missing[(br, p)]
                    confirmed.append(p)
            if confirmed:
                for p in confirmed:
                    old = st["current"].pop(p)
                    if p not in present:
                        until = clamp_until(old["expires"], now)
                        st["stale"][p] = {"until": until, "addrs": old["addrs"]}
                        if until != old["expires"]:
                            self.touched.add((br, p))  # derived from now; else keeps its origin
                        self._event(f"{br}: {p} replaced by {','.join(sorted(cur))}, deprecating")
                if len(st["stale"]) > MAX_STALE_PER_BRIDGE:
                    keep = sorted(st["stale"], key=lambda q: st["stale"][q]["until"])[-MAX_STALE_PER_BRIDGE:]
                    st["stale"] = {q: st["stale"][q] for q in keep}
                self.dirty = True
                self.schedule[br] = {"start": mono, "n": 0, "next": mono}
        due = {}
        for br, st in self.bridges.items():
            for p in [p for p, s in st["stale"].items() if s["until"] <= now]:
                del st["stale"][p]
                self.dirty = True
                self._event(f"{br}: {p} deprecation finished")
            if not st["stale"]:
                self.schedule.pop(br, None)
                continue
            if br not in bridges or not snap.get(br):
                continue  # only advertise next to a current prefix
            sched = self.schedule.setdefault(br, {"start": mono, "n": 0, "next": mono})
            if mono < sched["next"] or mono - self.last_send.get(br, -1e9) < MIN_GAP_S:
                continue
            prefixes = sorted(p for p in st["stale"] if p not in present)
            if prefixes:
                rdnss = sorted({a for p in prefixes for a in st["stale"][p]["addrs"]})
                due[br] = (prefixes, rdnss)
        return due

    def sent(self, br, mono):
        sched = self.schedule[br]
        self.last_send[br] = mono
        sched["n"] += 1
        if sched["n"] < len(BURST_OFFSETS_S):
            sched["next"] = sched["start"] + BURST_OFFSETS_S[sched["n"]]
        else:
            sched["next"] = mono + REPEAT_S + random.uniform(0, REPEAT_JITTER_S)

    def counts(self):
        return sum(len(st["stale"]) for st in self.bridges.values())


def run_ip(*args):
    out = subprocess.run(["ip", "-j", *args], capture_output=True, text=True,
                         check=True, timeout=CMD_TIMEOUT_S).stdout
    return json.loads(out or "[]")


def dnsmasq_running():
    for comm in glob.glob("/proc/[0-9]*/comm"):
        try:
            with open(comm) as fh:
                if fh.read().strip() == "dnsmasq":
                    return True
        except OSError:
            pass
    return False


def send_blocked(bridges):
    """Why sending must wait, or None. Our RA renews the router entry on clients, so it goes
    out only while the gateway routes IPv6 and dnsmasq advertises it too."""
    if not has_default_route(run_ip("-6", "route", "show", "table", "all", "default")):
        return "no IPv6 default route"
    if not dnsmasq_running():
        return "dnsmasq not running"
    return None


def read_dnsmasq():
    text = ""
    for f in sorted(glob.glob(DNSMASQ_GLOB)):
        with open(f) as fh:
            text += fh.read() + "\n"
    return parse_dnsmasq(text)


def link_info(dev):
    link = run_ip("-6", "addr", "show", "dev", dev, "scope", "link")[0]
    lladdr = next(a["local"] for a in link["addr_info"]
                  if a.get("local", "").startswith("fe80") and not a.get("tentative"))
    mac = run_ip("link", "show", "dev", dev)[0]["address"]
    return link["ifindex"], lladdr, bytes.fromhex(mac.replace(":", ""))


def send_ra(dev, cfg, prefixes, rdnss, link, dry_run):
    ifindex, lladdr, mac = link
    pkt = build_ra(cfg["prf"], cfg["rl"], mac, prefixes, rdnss)
    if dry_run:
        log(f"[dry-run] RA {dev} deprecate={','.join(prefixes)} rdnss0={','.join(rdnss)}")
        return
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, dev.encode())
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, ifindex)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, 0)
        s.bind((lladdr, 0, 0, ifindex))
        s.sendto(pkt, ("ff02::1", 0, 0, ifindex))
    finally:
        s.close()


def write_atomic(path, data, mode=0o600):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    dfd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def load_state():
    try:
        with open(STATE_FILE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def main():
    dry_run = "--dry-run" in sys.argv
    os.makedirs(RUN_DIR, exist_ok=True)
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another instance is running")
        return 1
    tracker = Tracker(None if dry_run else load_state())
    log(f"started{' (dry-run)' if dry_run else ''}, tracking {sum(len(s['current']) for s in tracker.bridges.values())}"
        f" prefixes, deprecating {tracker.counts()}")
    last_skipped, last_error, error_polls, save_failed = None, None, 0, False
    last_pause = None
    status, status_written = None, 0.0
    last_send_wall = None
    while True:
        now, mono = time.time(), time.monotonic()
        error = None
        bridges, snap = {}, {}
        try:
            bridges, skipped = read_dnsmasq()
            if skipped != last_skipped:
                for reason in skipped:
                    log(f"skipped {reason}")
                last_skipped = skipped
            snap, present = parse_addrs(run_ip("-6", "addr", "show"), bridges)
            due = tracker.update(bridges, snap, present, now, mono)
            pause = None
            for br, (prefixes, rdnss) in due.items():
                try:
                    link = link_info(br)
                    # Rechecked after the link lookup, right before this send.
                    pause = send_blocked(bridges)
                    if pause:
                        break
                    fresh = drop_present({br: (prefixes, rdnss)}, parse_addrs(run_ip("-6", "addr", "show"), bridges)[1])
                    if br in fresh:
                        send_ra(br, bridges[br], *fresh[br], link, dry_run)
                        tracker.sent(br, mono)
                        last_send_wall = int(now)
                except (OSError, subprocess.SubprocessError, ValueError, IndexError, StopIteration, KeyError) as e:
                    error = f"send on {br} failed: {e!r}"
            if due and pause != last_pause:
                log(f"sending paused: {pause}" if pause else "sending resumed")
                last_pause = pause
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            error = f"snapshot failed: {e!r}"
            tracker.lost_sight()
        if error != last_error:
            if error:
                log(error)
            last_error = error
        # A single failed poll is not worth an error on the status card.
        error_polls = error_polls + 1 if error else 0
        reported_error = error if error_polls >= ERROR_REPORT_POLLS else None
        if tracker.dirty and not dry_run:
            try:
                write_atomic(STATE_FILE, json.dumps(tracker.to_state(), sort_keys=True))
                tracker.dirty = False
                tracker.mark_saved()
                save_failed = False
            except OSError as e:
                if not save_failed:
                    log(f"saving state failed, retrying: {e!r}")
                save_failed = True
        deprecating = tracker.counts()
        current = any(snap.get(br) for br in bridges)
        new_status = {
            "state": "error" if reported_error else "deprecating" if deprecating else "ready" if current else "waiting",
            "networks": len(bridges),
            "deprecating": deprecating,
            "last_send": last_send_wall,
            "last_event": tracker.events[-1] if tracker.events else None,
            "error": reported_error or ("saving state failed" if save_failed else None),
        }
        if new_status != status or mono - status_written >= STATUS_HEARTBEAT_S:
            try:
                write_atomic(STATUS_FILE, json.dumps(dict(new_status, heartbeat=int(now))), 0o644)
                status, status_written = new_status, mono
            except OSError:
                pass
        del tracker.events[:-1]
        time.sleep(POLL_S)


if __name__ == "__main__":
    sys.exit(main())
PYEOF
); then
    log "Writing $DAEMON failed."
    exit 1
fi

if ! UNIT_CHANGED=$(install_if_changed "$UNIT" 644 <<'EOF'
[Unit]
Description=Deprecate stale delegated IPv6 prefixes on LAN (RFC 9096)
After=network.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/env python3 -u /data/ipv6-prefix-deprecation/ipv6-prefix-deprecation.py
Restart=always
RestartSec=10
Nice=10
RuntimeDirectory=ipv6-prefix-deprecation
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/data/ipv6-prefix-deprecation
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
); then
    log "Writing $UNIT failed."
    exit 1
fi

if [ -n "$UNIT_CHANGED" ] && ! systemctl daemon-reload; then
    log "systemctl daemon-reload failed."
    exit 1
fi
if ! systemctl enable ipv6-prefix-deprecation >/dev/null 2>&1; then
    log "Enabling the service failed."
    exit 1
fi
if [ -n "$DAEMON_CHANGED$UNIT_CHANGED" ]; then
    ACTION=restart
else
    ACTION=start
fi
if ! systemctl "$ACTION" ipv6-prefix-deprecation; then
    log "systemctl $ACTION failed: $(journalctl -u ipv6-prefix-deprecation -n 3 -o cat --no-pager 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

sleep 2
if systemctl is-active --quiet ipv6-prefix-deprecation; then
    log "Service active."
else
    log "Service failed to start: $(journalctl -u ipv6-prefix-deprecation -n 3 -o cat --no-pager 2>/dev/null | tr '\n' ' ')"
    exit 1
fi
