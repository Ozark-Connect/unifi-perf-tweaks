# UniFi OS 6.0.16 Compatibility Verification

**Result: compatible.** Static check of the UCG-Fiber image on 2026-10-28. No live check.

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.0.16.8ea8e65.261028.1047` |
| `.bin` md5 | `d4590719e43c84082945e6f26bd88f2e` (954,892,187 bytes) |
| Rootfs | zstd squashfs at offset `16088722`, 52,427 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Wed Oct 28 10:48:38 CST 2026` (rebuilt), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.15 UCG-Fiber image |

| Tweak | Static (UCG-Fiber image) |
|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` byte-identical to 6.0.15 |
| 06 + 07 MongoDB | ✓ `mongod`, `mongodump`, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.15 |
| 08 + 09 PostgreSQL | ✓ `/etc/default/postgresql/14-apps`, `pg-cluster-setup`, PostgreSQL 14 binaries, configs and units identical to 6.0.15. No new `14-apps` reference |
| `mongodb-ssd-decommission.sh` | ✓ Its dependencies are covered by the 06 + 07 and 08 + 09 rows |
| 10 journald | ✓ `journald.conf` and `syslog-ng/` identical to 6.0.15 |
| 15 fan | ✓ `ustd` unchanged (6.0.11). `ufcd.service` identical. `ufcd`, `uhwd`, `usdbd`, all `statusdb` modules, `fan_ctrl.so` and `fan_ctrl_sm.so` `.text`-identical to 6.0.15 |

## Kernel

The decompressed kernel `Image` is the same size as 6.0.15 (13,395,976 bytes). Only 53 bytes differ: the two build-timestamp banners, the 20-byte build-id, and three initramfs cpio mtime fields. The per-function kallsyms compare finds no changed function, and the symbol set is identical (36,164 entries). The device tree is byte-identical to 6.0.15. This is a rebuild with no code change.

## Modules

Same 362-module set as 6.0.15. All 362 are byte-identical to 6.0.15, including `qca-ssdk.ko` (md5 `e4fd1d4e360a0c4ceaf74598dbda3114`). The symbols and the `0x690`/`0x6d0` cache offsets are intact by construction.

## Userland

Same 583 packages as 6.0.15, none added or removed. 11 packages changed version. None of `python3`, `systemd`, `syslog-ng`, `mongod`, PostgreSQL or `ustd` changed. Notable: `ubnt-tools` 6.0.21 → 6.0.22, `udapi-bridge` 0.35 (rev 10 → 13), new revisions of `udapi-server`/`libudapi`, base-files 6.0.110 → 6.0.111. Debian updates: `tzdata` 2026c → 2026e, `libbrotli1` 1.1.0-2+b7 → 1.1.0-2+deb13u1.

`ubnt-device-info` still links to `ubios-udapi-server`, which changed with `udapi-server`. The `model_short` string is present. `ubnthal.ko` is byte-identical.

The unit set and every unit file are identical to 6.0.15. `/etc/cron.d` is identical.

No new reference `.ko` (byte-identical to `research/qca-ssdk-compare/qca-ssdk-6.0.15.ko`). Working files: `~/fw-6016/` on the NAS.
