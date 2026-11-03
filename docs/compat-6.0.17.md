# UniFi OS 6.0.17 Compatibility Verification

**Result: compatible.** Static check of the UCG-Fiber image on 2026-11-03. No live check.

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

## Kernel

The decompressed kernel `Image` is the same size as 6.0.16 (13,395,976 bytes), and the symbol set is identical (36,164 entries). The per-function kallsyms compare finds two changed functions. Every other difference is the resulting address shift.

| Function | 6.0.16 | 6.0.17 |
|---|---|---|
| `inet_sock_destruct` | `kfree(inet->inet_opt)` | `if (opt) kfree_rcu(opt)` (344 → 352 bytes) |
| `tcp_v4_reqsk_destructor` | `kfree(ireq->ireq_opt)` | `if (opt) kfree_rcu(opt)` (24 → 36 bytes) |

This is the backport of upstream `e3f33b0a1d89` ("ipv4: free inet_opt and ireq_opt after an RCU grace period"), the fix for CVE-2026-98432. It closes a use-after-free where a retransmitted SYN builds a SYN-ACK from IP options that another CPU frees. Neither function is on a tweak path.

## Device tree: new UCG-Fiber v2 configuration

The FIT adds `fdt-2` ("ipq9574 ucgfiber v2") and a configuration `ucgfiber-2`, now the default. `fdt-1` is byte-identical to 6.0.16, and `ucgfiber-1` is still present. `fdt-2` differs from `fdt-1` in one node:

| Property (`/soc/i2c@78b8000/rtl8238b@20`) | `fdt-1` (v1) | `fdt-2` (v2) |
|---|---|---|
| `compatible` | `ui,rtl8238b` | `ui,rtl8238c` |
| `ui,rtl-fw-by-chip-set` | absent | present |

The uniphy, SFP and switch nodes are identical, so the SGMII+ modules apply to v2 hardware unchanged. `dtb_combined.bin` (bootloader) is byte-identical to 6.0.16.

## Modules

Same 362-module set as 6.0.16. 360 are byte-identical, including `qca-ssdk.ko` (md5 `e4fd1d4e360a0c4ceaf74598dbda3114`) and `ubnthal.ko`. The symbols and the `0x690`/`0x6d0` cache offsets are intact by construction.

The two changed modules are the PoE driver (`kmod-poe-driver` 0.3.3-11 → 0.3.3-10, different git hash):
- `udx_poe_rtl.ko`: code change. It adds RTL8238C and RTL8233C chip data, firmware `rtl8238c.bin`, and a chip-set read (`rtl_get_chip_set`) that selects the chip data when `ui,rtl-fw-by-chip-set` is set.
- `udx_poe_class.ko`: only the embedded Jenkins source path changed.

## Userland

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
