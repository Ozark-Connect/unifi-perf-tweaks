# UniFi OS 6.0.10 Compatibility Verification

**Result: compatible.** Static check only, 2026-09-26. Nothing was run on a gateway.

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.0.10.b3f3c92.260923.1028` |
| `.bin` md5 | `9281d7006108a707a707e77caa2f3e97` (953,156,007 bytes) |
| Rootfs | zstd squashfs at offset `16076894`, 52,429 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Wed Sep 23 10:29:56 CST 2026` (rebuilt), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.9 modules and package list pulled from ATL, 6.0.7 rootfs for configs and units |

| Tweak | Status | Evidence |
|---|---|---|
| 19 + 20 SGMII+ | ✓ | `qca-ssdk.ko` `.text` byte-identical to 6.0.9 |
| 06 + 07 MongoDB | ✓ | `mongod` binary, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.7 |
| 10 journald | ✓ | `journald.conf` and `syslog-ng/` identical to 6.0.7 |
| 15 fan | ✓ | `ufcd.service` identical to 6.0.7, enabled. `ustd` 6.0.8 → 6.0.9 |

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

## Outstanding

- **SGMII+ live load on a UCG-Fiber 6.0.x** (Lab box). Carried over from 6.0.7.
- The `ustd` 6.0.9 `sdb_client` and `ufcd` binaries changed. Script 15 needs a post-upgrade read of SDB `config.fan` to confirm the tuned setpoints hold.

Reference `.ko`: `research/qca-ssdk-compare/qca-ssdk-6.0.10.ko`. Working files: `~/fw-6010/` on the NAS.
