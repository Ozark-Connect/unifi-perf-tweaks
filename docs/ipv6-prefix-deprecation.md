# ipv6-prefix-deprecation

**Script:** [`scripts/30-ipv6-prefix-deprecation.sh`](../scripts/30-ipv6-prefix-deprecation.sh)
**Compatibility:** Tested on UCG-Fiber, UniFi OS 6.0.16 and 6.0.17, UniFi Network 11.0.99. Needs `python3` (part of the 6.0.x firmware).
**Risk level:** Low - it only sends Router Advertisements; removing it stops them

## Problem

With ISPs that hand out a new delegated prefix (DHCPv6-PD) on every PPPoE session, each reconnect or gateway reboot renumbers the LAN. UniFi OS moves the LAN networks to the new /64s, but in my tests it never told clients that the old ones were gone:

- When the prefix changes, `ubios-udapi-server` sends SIGTERM to dnsmasq before it removes the old PD addresses from the bridges. The new dnsmasq instance has never seen the old prefix, so it cannot advertise it with lifetime 0.
- Clients keep the old addresses preferred for the rest of the preferred lifetime the gateway advertised (30 minutes with my ISP's delegation). New connections from those addresses go nowhere, so IPv6 looks broken until the old prefix expires or the client reconnects to the network.

RFC 7084 (L-13) and RFC 9096 ask the router to advertise a vanished prefix with preferred lifetime 0 instead. On a UCG-Fiber with Telekom PPPoE the gateway sent no deprecating RA in my packet captures, whichever way the session went down: `kill -HUP` on pppd, `ip link set ppp0 down`, pulling the fiber, and a reboot. Another user reported that their UCG-Fiber does deprecate the old prefix after a modem restart, so this may depend on the setup.

## What the Script Does

The boot script installs a small Python daemon (standard library only) as the systemd service `ipv6-prefix-deprecation`:

1. Every 3 seconds it reads the dnsmasq configuration UniFi generates and the global /64s on each LAN bridge. It only watches networks that dnsmasq serves with SLAAC (`constructor:<bridge>,ra-only` with an `ra-param` line).
2. When a bridge has a new prefix and an old one has been gone from all interfaces for two snapshots in a row, it sends Router Advertisements for the old /64 with valid and preferred lifetime 0, and withdraws the gateway's old addresses as DNS servers (RDNSS lifetime 0). Router preference and lifetime come from the same `ra-param` line dnsmasq uses.
3. It sends three RAs, about 0, 6 and 18 seconds after the old prefix is confirmed gone (targets of 0, 4 and 16 seconds, rounded up to the next poll), then one about every 2 minutes, so clients that were asleep or roaming also get it. A deprecation runs for the old prefix's remaining valid lifetime, at least 2 hours and at most 24 hours.
4. It keeps the prefixes it has seen in `/data/ipv6-prefix-deprecation/state.json`, so after a reboot it still knows the prefix from before the reboot.

It never changes addresses, routes or the UniFi configuration. It only sends while the gateway has an IPv6 default route and dnsmasq is running, and never for a prefix that is still configured on any interface, so a prefix that comes back is not deprecated.

| Path | Purpose |
|---|---|
| `/data/ipv6-prefix-deprecation/ipv6-prefix-deprecation.py` | the daemon, rewritten by the boot script only when its content changes |
| `/data/ipv6-prefix-deprecation/state.json` | prefix history, written when prefixes change; a renewed lifetime is only written once it has grown by more than an hour |
| `/etc/systemd/system/ipv6-prefix-deprecation.service` | unit, checked on every boot and rewritten when missing or changed |
| `/run/ipv6-prefix-deprecation/status.json` | current state, RAM only |

While nothing changes, the daemon runs one `ip -j -6 addr show` every 3 seconds and writes `state.json` about once an hour, when renewed lifetimes have moved on by more than an hour.

## Install

Needs [udm-boot](prerequisites.md) like the other scripts.

```bash
scp scripts/30-ipv6-prefix-deprecation.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/30-ipv6-prefix-deprecation.sh && /data/on_boot.d/30-ipv6-prefix-deprecation.sh"
```

The script is idempotent: on later boots it only rewrites the daemon or the unit when they changed, and starts the service.

## Verification

```bash
systemctl is-active ipv6-prefix-deprecation
cat /run/ipv6-prefix-deprecation/status.json
journalctl -u ipv6-prefix-deprecation -n 20
```

`status.json` shows one of four states: `waiting` (no LAN prefix yet, for example while the WAN is down), `ready` (tracking prefixes), `deprecating` (old prefixes are being tracked for deprecation; sending pauses while the gateway has no IPv6 default route) or `error`. After a prefix change the journal shows one line per bridge, for example `br0: <old>/64 replaced by <new>/64, deprecating`.

On a client, the old addresses should turn deprecated within seconds after the new prefix appears: `ip -6 addr` on Linux shows `preferred_lft 0sec`, `ifconfig` on macOS shows `deprecated`. Linux keeps them valid for up to 2 more hours; that is the two-hour rule in RFC 4862, and the addresses are no longer used for new connections.

## Results

On a UCG-Fiber with Telekom FTTH (PPPoE, new /56 on every session), three LAN networks. The table shows when the first deprecating RA went out, measured from the new prefix appearing on the LAN:

| Event | Date, UniFi OS | Deprecation after the new prefix |
|---|---|---|
| `kill -HUP` on pppd | 2026-11-06, 6.0.17 | about 5 s |
| `ip link set ppp0 down` | 2026-11-01, 6.0.16 | about 3 s |
| Fiber pulled for 90 s | 2026-11-01, 6.0.16 | about 3 s |
| Reboot | 2026-11-01, 6.0.16 | about 7 s |

The delay depends on the duplicate address detection of the new address, where the 3-second poll falls, and the second confirming snapshot. These four runs fell between 3 and 7 seconds.

macOS and Ubuntu (NetworkManager) marked the old addresses deprecated and used the new prefix without reconnecting to the network. Without the script, macOS kept the old prefix preferred and connections from it timed out. After the reboot, IPv6 from the LAN still took about 2 to 3.5 minutes to work, also from the new prefix. I haven't looked into that delay; the deprecation itself went out on time.

## Limitations

- Only SLAAC networks are covered. Networks where dnsmasq runs stateful DHCPv6 are skipped and logged.
- A prefix the daemon never saw, for example from before the first install, is not deprecated.
- Tested on one UCG-Fiber with one ISP and with macOS and Linux clients. Windows, Android and iOS were not tested. There is no model check; other gateways with `python3` and the same dnsmasq layout should work but are untested.
- The handling of large clock steps (for example NTP correcting the clock after boot) is covered by unit tests, not by a live test.
- The RAs come from the bridge's link-local address like dnsmasq's own, but the daemon does not coordinate its timing with dnsmasq. Two RAs can be closer together than the 3 seconds RFC 4861 asks for.

## Tests

[`tests/test_ipv6_prefix_deprecation.py`](../tests/test_ipv6_prefix_deprecation.py) extracts the daemon from the boot script and tests it with the standard library only:

```bash
python3 tests/test_ipv6_prefix_deprecation.py
```

## Reverting

```bash
rm -f /data/on_boot.d/30-ipv6-prefix-deprecation.sh
systemctl disable --now ipv6-prefix-deprecation
rm -f /etc/systemd/system/ipv6-prefix-deprecation.service
systemctl daemon-reload
rm -rf /data/ipv6-prefix-deprecation
```

Deprecations clients have already received stay until they expire or the client reconnects.
