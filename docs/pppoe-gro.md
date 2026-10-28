# pppoe-gro (GRO/GSO for PPPoE)

**Script:** [`scripts/25-pppoe-gro.sh`](../scripts/25-pppoe-gro.sh)
**Module:** [`modules/pppoe-gro/`](../modules/pppoe-gro/) (GPL-2.0, see its `LICENSE`)
**Compatibility:** UCG-Fiber (IPQ9574, kernel 5.4.213-ui-ipq9574), UniFi OS 6.0.11 build only (see [After a firmware update](#after-a-firmware-update))
**Risk level:** Medium - kernel module bound to one kernel build, touches the receive path of every WAN packet
**Status:** Testing

## Problem

On a PPPoE WAN, every downloaded packet crosses the CPU on its own. The 5.4 vendor kernel has no GRO handler for PPPoE session frames, so the receive path never merges consecutive TCP segments the way it does on a plain Ethernet WAN. With Smart Queues on, each packet then walks PPPoE, `ppp0`, the ingress mirror to `ifbppp0`, HTB, fq_codel, routing and NAT individually. `tc -s qdisc show dev ifbppp0` shows `maxpacket 1492`.

On a UCG-Fiber with a 1 Gbit PPPoE line this caps the download with Smart Queues at about 790 Mbit/s, with all four cores near 100 %. A single TCP flow is pinned to one core, so two downloads reach only 500-700 Mbit/s even when the other cores are idle.

## What the module does

`pppoe_gro.ko` registers a GRO/GSO packet offload for `ETH_P_PPP_SES` (0x8864). It is a backport of Linux commit [`55a5d8fca836`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=55a5d8fca8365312ed53bc93ae1af67ee35c2915) ("net: pppoe: implement GRO/GSO support", Felix Fietkau and Qingfang Deng, merged in Linux 7.2) to the 5.4 vendor kernel.

- **GRO:** consecutive PPPoE frames of the same session and TCP flow are merged into one large skb before PPP decapsulation. The inner IPv4/IPv6 and TCP GRO handlers of the kernel do the actual merging, so the usual GRO rules apply (no merging across flags, options or fragments). The PPPoE length field is rewritten to the aggregated length, so the unmodified vendor `pppoe_rcv()` accepts the aggregate.
- **GSO:** an aggregate that leaves the gateway still PPPoE-encapsulated (bridged or relayed PPPoE) is segmented in software again. A locally terminated PPPoE WAN never uses this path.
- **`wan_dev` parameter:** only frames received on this device are aggregated (default `eth6`). It must be the physical device; with VLAN 7 the session runs on `eth6.7`, but GRO sees `eth6`. The boot script checks that the PPPoE session really runs on it or on a VLAN on top of it.
- **Counters** in `/sys/kernel/debug/pppoe_gro/stats` (aggregates, average segments per aggregate, skipped frames, errors).

The vendor `pppoe.ko` stays untouched. It exports QCA-specific symbols that SFE, ECM and the PPE PPPoE manager import, so it can't be replaced.

## Measurements

UCG-Fiber, UniFi OS 6.0.11, Deutsche Telekom FTTH 1000/500 over PPPoE on VLAN 7, WAN on eth6 at 2.5G with the SGMII+ module, Smart Queues on with the HTB root at 898 Mbit nominal. Load from one wired client. A/B in the order with, without, without, with module, two runs per state, same load each time. This table was measured on 2026-10-24 with module v0.3; v0.4 has the same GRO code and only adds the GSO callback and uses cheaper per-CPU increments for the debug counters.

| Load | Goodput without -> with | CPU %-points per 100 Mbit | RTT p95 to non-anycast hosts under load |
|---|---|---|---|
| 2 TCP flows, IPv4 + NAT | 546 / 597 -> 849 / 862 Mbit/s | 40 -> 24 | 23 -> 17 ms |
| 2 TCP flows, IPv6 | 504 / 713 -> 799 / 869 Mbit/s | 41 -> 24 | 24 -> 17 ms |
| 8 TCP flows, IPv4 + NAT | 795 / 767 -> 824 / 864 Mbit/s | 36 -> 30 | 36 -> 17 ms |
| 8 TCP flows, IPv6 | 775 / 812 -> 845 / 862 Mbit/s | 41 -> 28 | 33 -> 18 ms |
| Ookla (multi-flow) | 805 / 844 -> 858 / 881 Mbit/s | 39 -> 32 | 43 -> 26 ms |
| QUIC download (HTTP/3) | 518 / 821 -> 683 / 783 Mbit/s | 39 -> 39 | 52 -> 46 ms |

CPU at the same throughput, measured on 2026-10-24 with v0.4 (4 TCP flows, rate-limited below the shaper, Protect running on the gateway, same A/B order). Packet processing is the softirq time summed over the four cores (400 % = whole SoC); total CPU on a gateway with Protect varies too much between runs to show the difference at lower rates.

| Download rate | Packet processing without | with |
|---|---|---|
| 300 Mbit/s | 68 % (0.7 cores) | 41 % (0.4 cores) |
| 500 Mbit/s | 88 % (0.9 cores) | 53 % (0.5 cores) |
| 700 Mbit/s | 127 % (1.3 cores) | 63 % (0.6 cores) |

At 700 Mbit/s that is 0.64 cores, about 16 % of the SoC's CPU, left for other services such as Protect.

"CPU %-points per 100 Mbit" is the sum of the four per-core averages divided by goodput. Without the module, fq_codel dropped hundreds to thousands of packets per run under TCP load. With the module it dropped almost none and marked ECN instead.

TCP aggregates average 6 segments with 2 flows and 4-5 with 8 flows, so more parallel flows still cost more CPU. QUIC and other UDP traffic are not aggregated at all (5.4 has no GRO for forwarded UDP), so they gain nothing and a single fast UDP flow can still saturate one core.

## Important caveats

### Smart Queues rate is applied 2-4 % higher

HTB counts an aggregate as its `skb->len`, which contains the IP and TCP headers once instead of once per original segment. With the module, a given HTB rate lets more IP traffic through than it counts, and more for IPv6 than for IPv4. Measured on 2026-10-25 with 4 bulk TCP flows and the HTB root at 890 Mbit/s, 4 runs per protocol, comparing the bytes per counted segment in the HTB counters with the IP bytes per frame on `eth6` (assuming 26 bytes of overhead per frame): IPv4 TCP passed 1.9 % more than HTB counted (1464-1466 against 1491-1493 bytes), IPv6 TCP 4.2 % more (1432-1433 against 1493 bytes). Earlier runs at 898 Mbit/s agree: 1.5-2 % for IPv4 bulk TCP and 4-5 % for Ookla, which ran over IPv6. How far a Smart Queues rate tuned without the module moves toward the line rate depends on the IPv6 share of the traffic. Rates read from `ppp0` counters are low by a similar amount.

### Counters and captures see aggregates

`ppp0` packet counters, conntrack/DPI packet counts and captures on `eth6`/`ppp0` show aggregates up to 64 KiB instead of wire packets. Byte counts on `eth6` and the hardware port mirror are unaffected.

### Unloading under load

`rmmod pppoe_gro` while a download is running can drop the aggregates a CPU is holding at that moment, with a kernel warning per dropped aggregate. Stop downloads first. Loading under load is fine.

### Not tested

- `/sys/sfe/fast_tc_filter` set to 1, IPS/Suricata
- Bridged or relayed PPPoE (the GSO path), PPPoE without VLAN, RFC 4638 (MTU 1500), PPP compression/MPPE (the script refuses to load with those modules)
- UXG-Fiber, UCG-Ultra and any firmware other than 6.0.11
- Long-term operation (in progress)

### Tested so far

All with v0.4 on 2026-10-24. Deployment and an orderly reboot on the test gateway: the boot script loaded the module about 5.5 minutes after boot, after waiting out a PPPoE reconnect caused by the SGMII+ script switching eth6 to 2.5G, and released the marker 10 minutes later. A reboot during the 10-minute hold cleared the marker as intended. A forced PPPoE reconnect (SIGHUP to pppd) under download load with the module loaded: new session after about 8 seconds, aggregation continued on the new session at full rate, no errors in the counters or kernel log. With Smart Queues off, ECM hands the flows to the PPE after their first packets, so the module only sees those (about 0.2 % of the traffic in the test) and gains nothing; IPv4 and IPv6 downloads with checksum verification showed no errors at the handover.

## Pre-check

```bash
ssh root@<gateway-ip> 'uname -r; uname -v'
# Expected: 5.4.213-ui-ipq9574
#           #5.4.213 SMP PREEMPT Thu Oct 1 19:39:57 CST 2026
ssh root@<gateway-ip> 'cat /proc/net/pppoe'
# The Device column must be your WAN device or a VLAN on it (e.g. eth6.7 on eth6)
ssh root@<gateway-ip> 'lsmod | grep -E "^(ppp_deflate|bsd_comp|ppp_mppe) "'
# Must print nothing
```

## Deployment

The boot script needs udm-boot (see [prerequisites.md](prerequisites.md)).

```bash
ssh root@<gateway-ip> 'mkdir -p /data/pppoe-gro'
scp modules/pppoe-gro/pppoe_gro.ko root@<gateway-ip>:/data/pppoe-gro/
scp scripts/25-pppoe-gro.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> 'chmod +x /data/on_boot.d/25-pppoe-gro.sh'
# WAN not on eth6? Put the physical device name into /data/pppoe-gro/wan_dev (eth6, not eth6.7)
```

First run without a reboot:

```bash
ssh root@<gateway-ip> /data/on_boot.d/25-pppoe-gro.sh
# The script waits until ppp0 and the PPPoE session have been up for 60 s in a row (10 min at most), then loads
ssh root@<gateway-ip> 'cat /var/log/pppoe-gro.log; lsmod | grep pppoe_gro'
```

The script loads only if the running kernel build, kernel config, vendor `pppoe.ko` and `qca-nss-dp.ko` match a verified build and the module file matches its sha256. It checks the module hash again right before `insmod`. It writes `/data/pppoe-gro/loading.marker` before `insmod` (and does not load if it can't) and removes it 10 minutes later, or earlier on an orderly reboot or shutdown. Only a crash or power loss within those 10 minutes leaves the marker; the script then does not load again until you remove it. A second run while a load is less than 10 minutes old is refused for the same reason.

## Verification

```bash
ssh root@<gateway-ip> 'cat /sys/kernel/debug/pppoe_gro/stats'
# Under download load: complete grows, avg_segs around 4-6, complete_err stays 0
ssh root@<gateway-ip> 'tc -s qdisc show dev ifbppp0 | grep maxpacket'
# maxpacket well above 1492 (up to ~66000) means aggregates reach the shaper
```

## Reverting

```bash
# Immediate (stop downloads first)
ssh root@<gateway-ip> 'rmmod pppoe_gro'
# Permanent
ssh root@<gateway-ip> 'touch /data/pppoe-gro/disable'
# or remove /data/on_boot.d/25-pppoe-gro.sh
```

Reloading within 10 minutes of a load is refused because of `loading.marker`. After a manual `rmmod` (not after a crash) remove the marker first, then start the script again:

```bash
ssh root@<gateway-ip> 'rm /data/pppoe-gro/loading.marker; /data/on_boot.d/25-pppoe-gro.sh'
```

## After a firmware update

The firmware has no `CONFIG_MODVERSIONS`, so `vermagic` does not protect against a changed `struct sk_buff`. The module reads and writes `sk_buff` and `napi_gro_cb` fields directly; a layout change would corrupt memory. The script therefore refuses any build that is not listed in `VERIFIED_BUILDS` and logs the values it found.

To add a build: confirm that the functions touching these structs are unchanged, for example by comparing `skb_gro_receive`, `dev_gro_receive`, `napi_gro_complete` and `__skb_checksum_complete` between the old and new kernel image with PC-relative immediates masked, and that `pppoe.ko` and `qca-nss-dp.ko` are `.text`-identical. Then add a line with the new `uname -v` and the three sha256 values. A rebuild without code changes keeps the layout; a changed function in the skb code needs a closer look.

## Building

```bash
mkdir -p ~/pppoe-gro-build
ssh root@<gateway-ip> 'zcat /proc/config.gz' > ~/pppoe-gro-build/config
# from the repository root; the repository is mounted read-only
docker run --rm -v "$PWD":/repo:ro -v ~/pppoe-gro-build:/out \
  debian@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308 \
  bash /repo/modules/pppoe-gro/build.sh /out/config
# result: ~/pppoe-gro-build/pppoe_gro.ko and pppoe_gro.ko.sha256
```

`build.sh` runs in a pinned `debian:trixie` image, checks out the CodeLinaro QSDK kernel at a pinned commit inside the container, applies `skbuff-layout-pad.patch` and builds with Debian's cross gcc 14.2.0-19, the compiler of the vendor kernel. Ubiquiti's `struct sk_buff` has two private fields the public tree lacks (8 bytes before `len`, 4 bytes before `protocol`). The patch adds placeholders so all offsets match the vendor kernel; this was verified against the running kernel's disassembly. With the same inputs the output is byte-identical (sha256 `2acd7a1b7921364a2460670d06c382a7f6772faf7e7508431f696da454567875` for the 6.0.11 config). The image is pinned, but `build.sh` still installs the current trixie packages with `apt-get`; if Debian ships a newer cross gcc later, the script warns and the module is no longer byte-identical (it still builds against the same kernel tree).

## Credits

GRO/GSO logic: Felix Fietkau and Qingfang Deng, Linux commit 55a5d8fca836 (Tested-by Pablo Neira Ayuso, applied by Paolo Abeni). Differences in this backport: 5.4 GRO API, a refused instead of clamped length overflow in `gro_complete` (a clamped length would make the vendor `pppoe_rcv()` trim the aggregate), `gso_segment` clears all GSO feature bits (on 5.4 `NETIF_F_GSO_SOFTWARE` does not cover `NETIF_F_GSO_PARTIAL`), the `wan_dev` filter and the debug counters.
