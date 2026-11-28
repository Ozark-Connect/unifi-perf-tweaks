# UniFi OS 6.0.19 Compatibility Verification

**Result: compatible on UCG-Fiber and UXG-Fiber.** UCG-Fiber: static check of its image and a read-only live check on a production UCG-Fiber with SSD (08 + 09 + 15), on 2026-11-24. UXG-Fiber: static check of its own image and a read-only live check on a production UXG-Fiber (SGMII+ + 10 + 15), on 2026-11-28.

- [UCG-Fiber](#ucg-fiber)
- [UXG-Fiber](#uxg-fiber)

## UCG-Fiber

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.0.19.7ffc2e2.261119.2229` |
| `.bin` md5 | `b2cc977437eecffbb389fcc0199fc7ba` (953,738,153 bytes) |
| Rootfs | zstd squashfs at offset `16171566`, 52,432 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Thu Nov 19 22:30:58 CST 2026` (rebuilt), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.17 UCG-Fiber image |

| Tweak | Static (UCG-Fiber image) | Live (UCG-Fiber) |
|---|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` byte-identical to 6.0.17. Both device trees byte-identical | Not deployed |
| 06 + 07 MongoDB | ✓ `mongod`, `mongodump`, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.17 | N/A (gateway runs 08 + 09) |
| 08 + 09 PostgreSQL | ✓ `/etc/default/postgresql/14-apps`, `pg-cluster-setup`, `/etc/postgresql*`, `usr/share/postgresql-common/` and all units identical to 6.0.17. `postgresql-14` 14.24 → 14.25 (see below). No new `14-apps` reference | ✓ See below |
| `mongodb-ssd-decommission.sh` | ✓ Its dependencies are covered by the 06 + 07 and 08 + 09 rows | Not run |
| 10 journald | ✓ `journald.conf` and `syslog-ng/` identical to 6.0.17 | Not deployed |
| 15 fan | ✓ `ufcd.service` identical. `ustd` (still 6.0.11) rebuilt with Cython 3.3.0 → 3.3.1, so `ufcd`, `uhwd` and 9 of 12 `statusdb` modules changed `.text`, including `sdb_client.so` | ✓ See below |

### Kernel

The decompressed kernel `Image` is the same size as 6.0.17 (13,395,976 bytes). 100 bytes differ: the two version banners, the build-id, and initramfs cpio mtimes. The kallsyms dump is identical to 6.0.17 (36,164 entries, same addresses), and the per-function compare finds no changed function. The CVE-2026-98432 fix from 6.0.17 is still in place. `fdt-1` and `fdt-2` are byte-identical to 6.0.17, and the default configuration is still `ucgfiber-2`.

### Modules

Same 362-module set as 6.0.17. All 362 are byte-identical, including `qca-ssdk.ko` (md5 `e4fd1d4e360a0c4ceaf74598dbda3114`) and `ubnthal.ko`. The symbols and the `0x690`/`0x6d0` cache offsets are intact by construction.

### Userland

Same 583 packages as 6.0.17, none added or removed. Changed versions:

| Package | 6.0.17 | 6.0.19 |
|---|---|---|
| `postgresql-14`, `postgresql-client-14` | 14.24-1.pgdg13+2 | 14.25-1.pgdg13+1 |
| `postgresql-16`, `postgresql-client-16` | 16.15 | 16.16 |
| `postgresql-common`, `postgresql-client-common` | 293 | 295 |
| `libpq5` | 18.6 | 18.7 |
| `ustd` | 6.0.11 (`6f3dd819`) | 6.0.11 (`1fce2ea5`) |
| `unifi-core` | 6.0.130 | 6.0.132 |
| `uos`, `uos-discovery-client` | 6.0.4, 6.0.7 | 6.0.7, 6.0.8 |
| `udapi-server`, `libudapi` | rev 10 (`162d90d3`) | rev 3431 (`5fae1b7c`) |
| `nginx` | 1.30.6 | 1.30.7 |
| `apt`, `libapt-pkg7.0` | 3.0.3 | 3.0.4 |
| Debian security | | `libcares2` 1.34.5 → 1.34.9, `vim` deb13u1 → u2, `zlib1g` +b1 → deb13u1 |

Also bumped: `base-files` 6.0.111 → 6.0.112, `uid-agent`, `ulp-go`, `unifi-identity-update`, `ppp`, `wifiman-*`. None of `python3`, `systemd`, `syslog-ng` or `mongod` changed.

`ustd` changed only its git hash. In `ufcd`, `uhwd` and the `statusdb` modules, the string-table difference is the Cython runtime tag (`_cython_3_3_0` → `_cython_3_3_1`). The `SDBClient` API cannot be read statically (Cython). The live run below confirms it.

The PostgreSQL 14 minor update changes the binaries under `usr/lib/postgresql/14/` (1,012 files) and adds one bitcode file. The cluster layout that 08 and 09 need is unchanged: `PG_VERSION=14`, `DIR=/data/postgresql/14/apps`, `CLUSTER_NAME="apps"`, `CLUSTER_PORT=5434`.

`ubnt-device-info` still links to `ubios-udapi-server`, which changed with `udapi-server`. The `model_short` string is present.

The unit set (416) and every unit file are identical to 6.0.17. `/etc/cron.d` is identical.

### Live check

Read-only, on a production UCG-Fiber with SSD. It booted 6.0.19 at 15:36:47 UTC, and the running build and kernel banner match the image above. The deployed scripts 08, 09 and 15 are byte-identical to repo HEAD. `udm-boot` finished with status 0.

| Tweak | Live (UCG-Fiber) |
|---|---|
| 08 PostgreSQL offload | ✓ At boot, the SSD copy was authoritative. The script bound `/data/postgresql/14/apps/data` to the SSD and started cluster `14-apps`. The running server is 14.25 |
| 09 PostgreSQL backup | ✓ At boot, the script validated the cluster and both backup archives, and installed the helper and cron. The first nightly backup on 6.0.19 runs at 01:30 local time and is not yet observed |
| 15 fan | ✓ BEFORE stock (100/68/109/103), AFTER 65/55/85/90 at 15:42:18 UTC, no `ERROR`. `ufcd` restarted at 15:42:19, after the write. SDB `config.fan` still holds the tuned values at 20:36 UTC. `fan_ctrl_sm` maps = 4. Actuator: CPU 67.6 °C, between the tuned (65) and stock (100) setpoints, drives PWM 75 to 77 (about 3,500 rpm), above the 38 floor |

No new reference `.ko` (byte-identical to `research/qca-ssdk-compare/qca-ssdk-6.0.15.ko`). Working files: `~/fw-6019/` on the NAS.

## UXG-Fiber

| | |
|---|---|
| Build | `UXGA6AA.ipq9574.v6.0.19.a29a5cc.261125.1442` |
| `.bin` md5 | `9af37aed817516b5e5de25a763b29ba4` (354,731,996 bytes) |
| Rootfs | zstd squashfs at offset `16058898`, 22,643 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Wed Nov 25 14:43:45 CST 2026`, GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | UXG-Fiber 6.0.17 image. UCG-Fiber 6.0.19 image (same release) for `ustd` |

| Tweak | Static (UXG-Fiber image) | Live (UXG-Fiber) |
|---|---|---|
| 19 + 20 SGMII+ | ✓ All 360 modules byte-identical to UXG-Fiber 6.0.17, including `qca-ssdk.ko` (`e4fd1d4e…`). Device tree byte-identical to 6.0.17 | ✓ See below |
| 06 + 07 MongoDB | N/A. No `mongod`. The scripts exit at their model check | N/A |
| 08 + 09 PostgreSQL | N/A. No PostgreSQL `14-apps` cluster. The scripts exit at their model check | N/A |
| `mongodb-ssd-decommission.sh` | N/A, as 06 to 09 | N/A |
| 10 journald | ✓ `journald.conf` and `syslog-ng/` identical to 6.0.17 | ✓ See below |
| 15 fan | ✓ `ufcd.service` identical. `ustd` 6.0.11 rebuilt (`6f3dd819` → `1fce2ea5`, the UCG-Fiber 6.0.19 build): `ufcd`, `uhwd` and all `statusdb` modules `.text`-identical to UCG-Fiber 6.0.19, where script 15 ran live | ✓ See below |

The kernel `Image` is the same size as 6.0.17 and differs in 102 bytes; the per-function kallsyms compare finds no changed function. It differs from the UCG-Fiber 6.0.19 `Image` in 63 bytes.

Same 531 packages as 6.0.17. 37 changed version: `ustd` and `udapi-server` as on the UCG-Fiber, `nginx` 1.30.6 → 1.30.7, and Debian security updates (`libc6`, `openssl` 3.5.9, `sudo`, `krb5`, `nghttp2`, `zstd`, `node24`). None of `python3`, `systemd` or `syslog-ng` changed. The unit set (375), every unit file and `/etc/cron.d` are identical to 6.0.17. `ubnt-device-info` still carries `model_short`.

### Live check

Read-only, on a production UXG-Fiber. It booted 6.0.19 at 16:14:44 UTC, and the running build and kernel banner match the image above. The deployed scripts 10 and 15 are byte-identical to repo HEAD, and `udm-boot` finished with status 0.

| Tweak | Live (UXG-Fiber) |
|---|---|
| 20 SGMII+ (uniphy1, `eth6`) | ✓ Loaded 78 s after boot by the gateway's SFP management script, in place of script 20. Module md5 `0a89feab…`, the repo artifact. Full dmesg sequence: symbols resolved, port bitmap `0x62` → `0x42`, uniphy1 SGMII+ 2.5G, speed cache 1000 → 2500, speed reporting updated. `eth6` 2500Mb/s Full, uniphy1 clock 312.5 MHz. No rx or tx errors over 1.8 days (90 GB rx, 232 GB tx), 0 CRC errors |
| 19 SGMII+ (uniphy2, `eth5`) | Not tested |
| 10 journald | ✓ `Storage=volatile`, `ForwardToSyslog=no`. 33M in `/run/log/journal`, 4K in `/var/log/journal`. 14 `conf.d` files have their local `log` statements commented out, `wan-diag.conf` included |
| 15 fan | ✓ The upgrade reset SDB `config.fan` to stock (100/109/103). Script 15 applied 65/85/90 at 16:15:28 UTC with no `ERROR`; `ufcd` restarted the same second, after the write. SDB still holds the tuned values 1.8 days later. `fan_ctrl_sm` maps = 4. Actuator inconclusive: the hottest sensor read 59.1 °C, below the 65 °C setpoint, so PWM held the 38 floor |
| 06 to 09 | N/A |

Working files: `~/fw-6019-uxgf/` on the NAS.
