# ipv6-prefix-deprecation

**Script:** [`scripts/30-ipv6-prefix-deprecation.sh`](../scripts/30-ipv6-prefix-deprecation.sh)
**Compatibility:** Tested on UCG-Fiber, UniFi OS 6.0.16 and 6.0.17. Needs `python3` (part of the 6.0.x firmware).
**Risk level:** Low - it only sends Router Advertisements; removing it stops them

## Problem

With ISPs that hand out a new delegated prefix (DHCPv6-PD) on every PPPoE session, each reconnect or gateway reboot renumbers the LAN. UniFi OS moves the LAN networks to the new /64s, but it never tells clients that the old ones are gone:

- When the prefix changes, `ubios-udapi-server` sends SIGTERM to dnsmasq before it removes the old PD addresses from the bridges. The new dnsmasq instance has never seen the old prefix, so it cannot advertise it with lifetime 0.
- Clients keep the old addresses preferred for the rest of their preferred lifetime (up to 30 minutes with the stock settings). New connections from those addresses go nowhere, so IPv6 looks broken until the old prefix expires or the client reconnects to the network.

RFC 7084 (L-13) and RFC 9096 ask the router to advertise a vanished prefix with preferred lifetime 0 instead. On a UCG-Fiber with Telekom PPPoE this was the same for every way the session went down: `kill -HUP` on pppd, `ip link set ppp0 down`, pulling the fiber, and a reboot. In packet captures the gateway sent no deprecating RA in any of them.

## What the Script Does

The boot script installs a small Python daemon (standard library only) as the systemd service `ipv6-prefix-deprecation`:

1. Every 3 seconds it reads the dnsmasq configuration UniFi generates and the global /64s on each LAN bridge. It only watches networks that dnsmasq serves with SLAAC (`constructor:<bridge>,ra-only` with an `ra-param` line).
2. When a bridge has a new prefix and an old one has been gone for two snapshots in a row, it sends Router Advertisements for the old /64 with valid and preferred lifetime 0, and withdraws the gateway's old addresses as DNS servers (RDNSS lifetime 0). Router preference and lifetime come from the same `ra-param` line dnsmasq uses.
3. It sends a burst (0, 4 and 16 seconds) and then repeats every 2 minutes, so clients that were asleep or roaming also get it. A deprecation runs for the old prefix's remaining valid lifetime, at least 2 hours and at most 24 hours.
4. It keeps the prefixes it has seen in `/data/ipv6-prefix-deprecation/state.json`, so after a reboot it still knows the prefix from before the reboot.

It never changes addresses, routes or the UniFi configuration. It only sends while the gateway has an IPv6 default route and dnsmasq is running, and never for a prefix that is still configured on any interface, so a prefix that comes back is not deprecated.

| Path | Purpose |
|---|---|
| `/data/ipv6-prefix-deprecation/ipv6-prefix-deprecation.py` | the daemon, rewritten only when its content changes |
| `/data/ipv6-prefix-deprecation/state.json` | prefix history, written on changes and at most hourly for lifetime updates |
| `/etc/systemd/system/ipv6-prefix-deprecation.service` | unit, recreated on every boot |
| `/run/ipv6-prefix-deprecation/status.json` | current state, RAM only |

## Install

```bash
scp scripts/30-ipv6-prefix-deprecation.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/30-ipv6-prefix-deprecation.sh && /data/on_boot.d/30-ipv6-prefix-deprecation.sh"
```

The script is idempotent. It writes nothing to `/data` on a normal boot unless the daemon changed.

## Verification

```bash
systemctl is-active ipv6-prefix-deprecation
cat /run/ipv6-prefix-deprecation/status.json
journalctl -u ipv6-prefix-deprecation -n 20
```

`status.json` shows `ready` while it is tracking prefixes and `deprecating` while old prefixes are being advertised. After a prefix change the journal shows one line per bridge, for example `br0: <old>/64 replaced by <new>/64, deprecating`.

On a client, the old addresses should turn deprecated within seconds after the new prefix appears: `ip -6 addr` on Linux shows `preferred_lft 0sec`, `ifconfig` on macOS shows `deprecated`. Linux keeps them valid for up to 2 more hours; that is the two-hour rule in RFC 4862, and the addresses are no longer used for new connections.

## Results

On a UCG-Fiber with Telekom FTTH (PPPoE, new /56 on every session), three LAN networks:

| Event | Old prefix deprecated after the new one appeared |
|---|---|
| `kill -HUP` on pppd | about 5 s |
| `ip link set ppp0 down` | about 3 s |
| Fiber pulled for 90 s | about 3 s |
| Reboot | about 7 s, for the prefixes from before the reboot |

macOS and Ubuntu (NetworkManager) switched to the new prefix without reconnecting to the network. Without the script both kept the old prefix preferred for the rest of its preferred lifetime, about 20 minutes in the Ubuntu test.

The time from a new prefix to the deprecation depends on where the 3-second poll falls and on the two-snapshot confirmation, so it is between about 3 and 7 seconds.

## Limitations

- Only SLAAC networks are covered. Networks where dnsmasq runs stateful DHCPv6 are skipped and logged.
- A prefix the daemon never saw, for example from before the first install, is not deprecated.
- Tested on one UCG-Fiber with one ISP and with macOS and Linux clients. Windows, Android and iOS were not tested, and neither were other models.
- The RAs come from the bridge's link-local address like dnsmasq's own, but the daemon does not coordinate its timing with dnsmasq. Two RAs can be closer together than the 3 seconds RFC 4861 asks for.

## Reverting

```bash
rm -f /data/on_boot.d/30-ipv6-prefix-deprecation.sh
systemctl disable --now ipv6-prefix-deprecation
rm -f /etc/systemd/system/ipv6-prefix-deprecation.service
systemctl daemon-reload
rm -rf /data/ipv6-prefix-deprecation
```

Deprecations clients have already received stay until they expire or the client reconnects.
