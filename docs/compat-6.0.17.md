# UniFi OS 6.0.17 Compatibility Verification

**Result: compatible on UCG-Fiber, UXG-Fiber and UXG-Max.** Static checks of each model's own image: UCG-Fiber on 2026-11-03, UXG-Fiber and UXG-Max on 2026-11-04. Live check on a production UXG-Fiber on 2026-11-04.

- [UCG-Fiber](#ucg-fiber)
- [UXG-Fiber](#uxg-fiber)
- [UXG-Max](#uxg-max)

## UCG-Fiber

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.0.17.7bcad58.261103.1126` |
| `.bin` md5 | `0622bccf95dae549f9f7ff747fd4d644` (953,326,035 bytes) |
| Rootfs | zstd squashfs at offset `16169138`, 52,431 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Tue Nov 3 11:27:33 CST 2026` (rebuilt), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.16 UCG-Fiber image |

| Tweak | Static (UCG-Fiber image) |
|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` byte-identical to 6.0.16. The new v2 device tree differs from v1 only in the PoE node (see below) |
| 06 + 07 MongoDB | ✓ `mongod`, `mongodump`, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.16 |
| 08 + 09 PostgreSQL | ✓ `/etc/default/postgresql/14-apps`, `pg-cluster-setup`, PostgreSQL 14 binaries, configs and units identical to 6.0.16. No new `14-apps` reference |
| `mongodb-ssd-decommission.sh` | ✓ Its dependencies are covered by the 06 + 07 and 08 + 09 rows |
| 10 journald | ✓ `journald.conf` and `syslog-ng/` identical to 6.0.16 |
| 15 fan | ✓ `ustd` unchanged (6.0.11). `ufcd.service` identical. `ufcd`, `uhwd`, `usdbd`, all `statusdb` modules, `fan_ctrl.so` and `fan_ctrl_sm.so` `.text`-identical to 6.0.16 |

### Kernel

The decompressed kernel `Image` is the same size as 6.0.16 (13,395,976 bytes), and the symbol set is identical (36,164 entries). The per-function kallsyms compare finds two changed functions. Every other difference is the resulting address shift.

| Function | 6.0.16 | 6.0.17 |
|---|---|---|
| `inet_sock_destruct` | `kfree(inet->inet_opt)` | `if (opt) kfree_rcu(opt)` (344 → 352 bytes) |
| `tcp_v4_reqsk_destructor` | `kfree(ireq->ireq_opt)` | `if (opt) kfree_rcu(opt)` (24 → 36 bytes) |

This is the backport of upstream `e3f33b0a1d89` ("ipv4: free inet_opt and ireq_opt after an RCU grace period"), the fix for CVE-2026-98432. It closes a use-after-free where a retransmitted SYN builds a SYN-ACK from IP options that another CPU frees. Neither function is on a tweak path.

### Device tree: new UCG-Fiber v2 configuration

The FIT adds `fdt-2` ("ipq9574 ucgfiber v2") and a configuration `ucgfiber-2`, now the default. `fdt-1` is byte-identical to 6.0.16, and `ucgfiber-1` is still present. `fdt-2` differs from `fdt-1` in one node:

| Property (`/soc/i2c@78b8000/rtl8238b@20`) | `fdt-1` (v1) | `fdt-2` (v2) |
|---|---|---|
| `compatible` | `ui,rtl8238b` | `ui,rtl8238c` |
| `ui,rtl-fw-by-chip-set` | absent | present |

The uniphy, SFP and switch nodes are identical, so the SGMII+ modules apply to v2 hardware unchanged. `dtb_combined.bin` (bootloader) is byte-identical to 6.0.16.

### Modules

Same 362-module set as 6.0.16. 360 are byte-identical, including `qca-ssdk.ko` (md5 `e4fd1d4e360a0c4ceaf74598dbda3114`) and `ubnthal.ko`. The symbols and the `0x690`/`0x6d0` cache offsets are intact by construction.

The two changed modules are the PoE driver (`kmod-poe-driver` 0.3.3-11 → 0.3.3-10, different git hash):
- `udx_poe_rtl.ko`: code change. It adds RTL8238C and RTL8233C chip data, firmware `rtl8238c.bin`, and a chip-set read (`rtl_get_chip_set`) that selects the chip data when `ui,rtl-fw-by-chip-set` is set.
- `udx_poe_class.ko`: only the embedded Jenkins source path changed.

### Userland

Same 583 packages as 6.0.16, none added or removed. 10 packages changed version. None of `python3`, `systemd`, `syslog-ng`, `mongod`, PostgreSQL or `ustd` changed.

| Package | 6.0.16 | 6.0.17 |
|---|---|---|
| `nginx` | 1.30.4 | 1.30.6 |
| `tzdata`, `tzdata-legacy` | 2026e | 2026f |
| `vim-tiny`, `vim-common` | 9.1.1230-2 | 9.1.1230-2+deb13u1 |
| `libnss3` | 3.110-1+deb13u4 | 3.110-1+deb13u5 |
| `ubnt-tools` | 6.0.22 | 6.0.23 (`.text` identical, `.data` changes one field in two table entries) |
| `udapi-server`, `libudapi` | rev 10 (`04a1da9f`) | rev 10 (`162d90d3`) |
| `kmod-poe-driver` | 0.3.3-11 | 0.3.3-10 |

`ubnt-device-info` still links to `ubios-udapi-server`, which changed with `udapi-server`. The `model_short` string is present.

The unit files and `/etc/cron.d` are identical to 6.0.16. The ramdisk differs only in `mdadm.conf` (generation timestamp) and `ubnt-tools`.

No new reference `.ko` (byte-identical to `research/qca-ssdk-compare/qca-ssdk-6.0.15.ko`). Working files: `~/fw-6017/` on the NAS. Section compares use `~/tools-6017/secdiff.sh`, which writes `objcopy` output to a temp file: `objcopy -O binary ... /dev/stdout` in a pipe produces 0 bytes.

## UXG-Fiber

| | |
|---|---|
| Build | `UXGA6AA.ipq9574.v6.0.17.7bcad58.261103.1606` |
| `.bin` md5 | `d64d09431cc7288905afe86c4678fef2` (355,984,879 bytes), matches the published `.md5sum` |
| Rootfs | zstd squashfs at offset `16058386`, 22,643 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Tue Nov 3 16:08:01 CST 2026`, GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | UCG-Fiber 6.0.17 image (same release). UXG-Fiber 6.0.5 image for the device tree and `syslog-ng/` |

| Tweak | Static (UXG-Fiber image) |
|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` byte-identical to UCG-Fiber 6.0.17 (`e4fd1d4e…`). Device tree byte-identical to UXG-Fiber 6.0.5, where SGMII+ ran live |
| 06 + 07 MongoDB | N/A. No `mongod`. The scripts exit at their model check |
| 08 + 09 PostgreSQL | N/A. No PostgreSQL `14-apps` cluster. The scripts exit at their model check |
| `mongodb-ssd-decommission.sh` | N/A, as 06 to 09 |
| 10 journald | ✓ `journald.conf` identical to UCG-Fiber 6.0.17. `syslog-ng/` identical to UXG-Fiber 6.0.5 |
| 15 fan | ✓ `ufcd`, `uhwd` and `ufcd.service` byte-identical to UCG-Fiber 6.0.17. All `statusdb` modules `.text`-identical |

The kernel `Image` is the same size as the UCG-Fiber 6.0.17 `Image` and differs in 42 bytes: the two version banners, the build-id and three initramfs mtimes. The kernel code, including the CVE-2026-98432 fix, is the same as on the UCG-Fiber.

The image has 360 modules. 352 are byte-identical to UCG-Fiber 6.0.17, including `qca-ssdk.ko`, `qca-nss-dp.ko` and `ubnthal.ko`. Seven differ only in an embedded Jenkins build path (`UCGF` → `UXGFIBER`). The UXG-Fiber adds `gpiodev.ko` and has no `st7735fb.ko`, `ui-hdd-pwrctl.ko` or `ui_st_accel.ko`, as on 6.0.5.

Every package common to both images has the same version as on the UCG-Fiber. The UXG-Fiber has 10 platform packages of its own and no Network application.

Compared with the UCG-Fiber, `syslog-ng/conf.d/` adds `wan-diag.conf` with five local `file("/var/log/...")` routes. The file was present on 5.1.26 and 6.0.5. Script 10 finds routes by the `destination ... file("/var/log` pattern, so it disables these too.

### Live check

Read-only, on a production UXG-Fiber upgraded from 6.0.10. It booted 6.0.17 at 18:52:24 UTC. The running build matches the image above. The deployed scripts 10 and 15 are byte-identical to repo HEAD, and `udm-boot` finished with status 0.

| Tweak | Live (UXG-Fiber) |
|---|---|
| 20 SGMII+ (uniphy1, `eth6`) | ✓ Loaded at 18:55:06 UTC by the gateway's SFP management script, which loads it once the WAN is reachable, in place of script 20. Module md5 `bbd0a2c9…` (repo artifact). Full dmesg sequence: symbols resolved, port bitmap `0x62` → `0x42`, uniphy1 SGMII+ 2.5G, speed cache 1000 → 2500. `eth6` 2500Mb/s, uniphy1 clock 312.5 MHz, SerDes `0x07A10218` = `0x00000050`. `adpt_hppe_uniphy_mode_set` at `ffffffc008934488`, as on 6.0.5 and 6.0.10. No rx, tx or CRC errors |
| 19 SGMII+ (uniphy2, `eth5`) | Not tested |
| 10 journald | ✓ `Storage=volatile`, `ForwardToSyslog=no`. 7.2M in `/run/log/journal`, 4K in `/var/log/journal`. Local routes commented out. In `wan-diag.conf`, which the gateway regenerates at runtime, four `/var/log` routes are commented out and the fifth writes to `/dev/null` |
| 15 fan | ✓ The upgrade reset SDB `config.fan` to stock (100/109/103). Script 15 applied 65/85/90 at 18:55:17 UTC. `ufcd` restarted at 18:55:18, after the write. `fan_ctrl_sm` maps = 4. Actuator inconclusive: the hottest sensor read 64.3 °C, below the 65 °C setpoint, so PWM stayed at the 38 floor |
| 06 to 09 | N/A |

## UXG-Max

| | |
|---|---|
| Build | `UXGB.ipq5322.v6.0.17.7bcad58.261103.1606` |
| `.bin` md5 | `669697ce10374823544f4642949a899c` (339,999,937 bytes), matches the published `.md5sum` |
| Rootfs | zstd squashfs at offset `15748510`, 22,096 inodes |
| Kernel | `5.4.213-ui-ipq5322`, `#5.4.213 SMP PREEMPT Tue Nov 3 16:08:01 CST 2026`, GCC 14.2.0-19 |
| SoC | IPQ5322. The FIT has three device trees (`uxg-v1`, `uxg-v2`, `uxg-v3`), default `uxg-v3` |
| Baseline | UXG-Fiber 6.0.17 image (same release). This is the first UXG-Max round, so there is no earlier UXG-Max image |

| Tweak | Static (UXG-Max image) |
|---|---|
| 19 + 20 SGMII+ | N/A. The modules are built for `5.4.213-ui-ipq9574` and do not load on the `ipq5322` kernel |
| 06 + 07 MongoDB | N/A. No `mongod`. The scripts exit at their model check |
| 08 + 09 PostgreSQL | N/A. No PostgreSQL `14-apps` cluster. The scripts exit at their model check |
| `mongodb-ssd-decommission.sh` | N/A, as 06 to 09 |
| 10 journald | ✓ `journald.conf` identical to UXG-Fiber 6.0.17. `syslog-ng/` identical except that `vpn_bonding_log.conf` is absent |
| 15 fan | ✓ `ufcd`, `uhwd`, `ufcd.service` and all 109 `ustd` `.so` files byte-identical to UXG-Fiber 6.0.17 |

Every package common to the UXG-Max and UXG-Fiber images has the same version. The differences are the SoC packages (`ipq5322` vs `ipq9574` kernel, SSDK and NSS) and the board packages.

Script 15 changes only the PID categories that exist in the SDB `config.fan`, and the image does not show which categories the UXG-Max has. No UXG-Max stock setpoints are on record.

Working files: `~/fw-6017-uxgf/` and `~/fw-6017-uxgmax/` on the NAS.
