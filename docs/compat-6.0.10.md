# UniFi OS 6.0.10 Compatibility Verification

**Result: compatible.** Static check of the UCG-Fiber image on 2026-09-26. Live check on a production UXG-Fiber on 2026-09-29 ([below](#live-uxg-fiber-2026-09-29)).

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.0.10.b3f3c92.260923.1028` |
| `.bin` md5 | `9281d7006108a707a707e77caa2f3e97` (953,156,007 bytes) |
| Rootfs | zstd squashfs at offset `16076894`, 52,429 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Wed Sep 23 10:29:56 CST 2026` (rebuilt), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.9 modules and package list pulled from ATL, 6.0.7 rootfs for configs and units |

| Tweak | Static (UCG-Fiber image) | Live (UXG-Fiber) |
|---|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` `.text` byte-identical to 6.0.9 | ✓ loaded, eth6 2500Mb/s |
| 06 + 07 MongoDB | ✓ `mongod`, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.7 | n/a (no MongoDB on UXG-Fiber) |
| 10 journald | ✓ `journald.conf` and `syslog-ng/` identical to 6.0.7 | ✓ in effect |
| 15 fan | ✓ `ufcd.service` identical to 6.0.7. `ustd` 6.0.8 → 6.0.9 | ✓ re-applied after upgrade reset |

## qca-ssdk

md5 `9187a544018bd1cc5a64be7c7df754ac`, 3,446,432 bytes. Raw `.text` is byte-identical to 6.0.9 (md5 `3585bdae…`, 982,444 bytes). The symbol table has zero delta. The 476 differing whole-file bytes are build provenance: the build timestamp, the Jenkins job path (`8-16Ap` → `49-40dc`), `.modinfo` and the build-id. The `sfp_read_status` encodings for the `0x690`/`0x6d0` cache offsets are unchanged at `ca478`/`ca480`.

## Other modules

Same 362-module set as 6.0.9. 34 changed md5. 33 of them are `.text`-identical to 6.0.9 or 6.0.7.

**One module changed code: `qca-nss-dp.ko`** (`.text` 64,476 → 71,876). This change adds an EDMA loopback ring:

- 19 new functions (`edma_cfg_{rx,tx}_loopback_*`, `edma_{rx_alloc,rx_free}_buffer_loopback`, a debugfs stats file).
- 3 new module parameters: `edma_loopback_ring_size`, `edma_loopback_buffer_size`, `edma_loopback_feature_type`.
- 7 existing functions call into it: `edma_of_get_pdata`, `edma_hw_init`, `edma_init`, `edma_cleanup`, `edma_hang_recovery_handler`, `edma_debugfs_init`, `init_module`. No other function changed after normalizing addresses, branch targets and immediates.
- The 6.0.10 device tree enables it: `/soc/edma@3ab00000` has `qcom,num_loopback_rings = 1`, `qcom,loopback_queue_base = 0x38`, `qcom,loopback_num_queues = 8`. The 6.0.7 image has none of these properties.

The loopback ring is host-side EDMA ring and PPE queue plumbing. It does not touch port MAC, uniphy or PHY code. The SGMII+ module does not reference `qca-nss-dp` at all (its 10 symbols are all in `qca-ssdk`). No effect on the module contract.

## Userland

36 firmware packages changed version against 6.0.9. None is in the tweak dependency set (`python3`, `systemd`, `syslog-ng`, `mongod`, `gzip`, `tar`, `libc6` all unchanged). Notable: `ustd` 6.0.9, `unifi-core` 6.0.120, `ubnt-tools` 6.0.20, `unifi-hal`/`udapi-server` new revisions, identity stack 1.8.4 → 1.8.5, `bind9` 9.20.26 → 9.20.29.

One package is new: `ubntmdnsd` (mDNS discovery). It runs from `/etc/cron.d/mdns-job` every minute and adds no systemd unit. The unit set is identical to 6.0.7.

## Live: UXG-Fiber, 2026-09-29

Read-only. Nothing was loaded, restarted or re-run. All gateway access fell between 16:15:38 and 16:16:32 UTC.

Build `UXGA6AA.ipq9574.v6.0.10.244feee.260923.1702`, kernel `Wed Sep 23 17:04:31 CST 2026`. Upgraded and booted 2026-09-29 16:11 UTC. `udm-boot` active, `ExecMainStatus=0`. Deployed scripts 10 and 15 are byte-identical to repo HEAD. No `err`-priority entries from any tweak since boot.

**The UXG-Fiber `qca-ssdk.ko` and `qca-nss-dp.ko` are byte-identical to the UCG-Fiber 6.0.10 image** (md5 `9187a544…` and `d3becdb2…`). Earlier rounds always showed a provenance-only md5 difference between the two platforms. 6.0.10 has none, so the static analysis above applies to this box without change.

**19 + 20 SGMII+.** The loaded `force_uniphy1_sgmiiplus.ko` is the repo artifact (`bbd0a2c9…`). The full `dmesg` sequence ran at 16:13:22 UTC: symbols resolved, port bitmap `0x62 -> 0x42`, uniphy1 set to SGMII+ 2.5G, loop restarted, speed cache `1000 -> 2500`. eth6 reports `2500Mb/s` Full, with 1.10 GB rx and 0.94 GB tx and zero errors. All 10 symbols resolve in `/proc/kallsyms` at the same addresses as 6.0.5 on this box ([table](sfp-sgmiiplus.md)).

**10 journald.** `Storage=volatile`, `ForwardToSyslog=no`, `RuntimeMaxUse=40M`, journal 6.7M. The syslog-ng persist file is in `/run`. Active `log` statements route only to console, IDS/IPS, content filtering, ulogd and udapi remote. `auth.log`, `cron.log`, `daemon.log` and `messages` were last written in April.

**15 fan.** The upgrade reset SDB `config.fan` to stock (cpu 100 / rtl8372 109 / rtl8261 103). Script 15 found `ufcd.service`, wrote cpu 65 / rtl8372 85 / rtl8261 90, and restarted `ufcd` at 16:13:33 UTC. A fresh SDB read gives the tuned values, so the `ustd` 6.0.9 `SDBClient` `run`/`get`/`update` API works. The pwm holds at 38, the floor. That is correct, because every component is below its tuned setpoint: CPU 56.2 °C (65), rtl8372 69 °C (85), rtl8261 81 °C (90).

## Outstanding

- **SGMII+ live load on a UCG-Fiber 6.0.x** (Lab box). Carried over from 6.0.7.
- 06 + 07 on a live 6.0.10 UCG-Fiber. The static check found no change from 6.0.9, where both were confirmed live.
- The `rmmod` path and a link flap were not exercised. eth6 is the production WAN.

Reference `.ko`: `research/qca-ssdk-compare/qca-ssdk-6.0.10.ko`. Working files: `~/fw-6010/` on the NAS.
