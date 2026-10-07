# UniFi OS 6.0.11 Compatibility Verification

**Result: compatible.** Static check of the UCG-Fiber image on 2026-10-04. No live check.

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.0.11.5efda8b.261001.1936` |
| `.bin` md5 | `644860cd6290cb6f0dca48daec11ebd8` (953,261,991 bytes) |
| Rootfs | zstd squashfs at offset `16084574`, 52,429 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Thu Oct 1 19:39:57 CST 2026` (rebuilt), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.10 UCG-Fiber image |

| Tweak | Static (UCG-Fiber image) |
|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` byte-identical to 6.0.10 |
| 06 + 07 MongoDB | ✓ `mongod`, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.10 |
| 10 journald | ✓ `journald.conf` and `syslog-ng/` identical to 6.0.10 |
| 15 fan | ✓ `ufcd.service` and `ustd` `sdb_client` `.so` identical to 6.0.10. `ustd` unchanged at 6.0.9 |

## Kernel

The decompressed kernel `Image` is the same size as 6.0.10 (13,395,976 bytes). Only 105 bytes differ: the two build-timestamp banners, the initramfs cpio mtimes, and the build-id. The device tree is byte-identical to 6.0.10. This is a rebuild with no code change.

## qca-ssdk

md5 `9187a544018bd1cc5a64be7c7df754ac`, 3,446,432 bytes. Byte-identical to 6.0.10 (`cmp` clean), so the symbols and the `0x690`/`0x6d0` cache offsets are intact by construction.

## Other modules

Same 362-module set as 6.0.10. 5 changed md5, all from the `qca-nss-ecm` package (`ecm.ko`, `ecm-wifi-plugin.ko`, `ecm_ae_select.ko`, `ecm_ovs.ko`, `ecm_sfe_l2.ko`). All 5 are `.text`-identical to 6.0.10. The differing bytes are the Jenkins job path (`49-40dc` → `71-368K`) and the build-id.

## Userland

23 firmware packages changed version against 6.0.10. None is in the tweak dependency set (`python3`, `systemd`, `syslog-ng`, `mongod`, `gzip`, `tar`, `libc6` all unchanged). Notable: `unifi-core` 6.0.120 → 6.0.123, `uos` 6.0.3 → 6.0.4, `ulp-go` 1.14.6 → 1.14.7, new revisions of `udapi-server`/`libudapi`, `libubnt`, `miniupnpd` and `qca-ssdk-shell`. Debian security updates: `openssl`/`libssl3t64` deb13u2 → u3, `libpcre2` deb13u2 → u3, `libwebsockets` deb13u2 → u3.

`qca-ssdk-shell` is the userland `ssdk_sh` tool. The SGMII+ module does not use it.

No package was added or removed. The unit set and `/etc/cron.d` are identical to 6.0.10.

## Outstanding

- **SGMII+ live load on a UCG-Fiber 6.0.x** (Lab box). Carried over from 6.0.7.
- Live check of 06 + 07 + 10 + 15 on 6.0.11. The static check found no change from 6.0.10.

No new reference `.ko` (byte-identical to `research/qca-ssdk-compare/qca-ssdk-6.0.10.ko`). Working files: `~/fw-6011/` on the NAS.
