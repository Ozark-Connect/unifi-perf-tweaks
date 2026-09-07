# UniFi OS 6.0.7 Compatibility Verification

Verified 2026-09-07 (UTC), **static / bench-only**, on the first 6.0.x image for the **UCG-Fiber**. Firmware `UBNTUCGF.ipq9574.v6.0.7.5e82c39.260902.1411` (built 2026-09-02), `.bin` md5 `8af9bcf293dabab3a0b9f774f73a55a2` (951,407,922 bytes), zstd squashfs rootfs (929,965,148 bytes, 52,397 inodes) carved from offset `16074058` (`0xF5454A`). Nothing was run on a gateway.

**Scope:** SGMII+ kernel module (static) and the userland surface the deployed Performance Tweaks depend on (MongoDB SSD offload/backup 06+07, journald volatile 10, fan control 15). Same posture as the 5.1.26 → 5.1.31 rounds: the live SGMII+ load/unload and the "tweaks in effect" checks are deferred until a UCG-Fiber is on 6.0.7. Adaptive SQM and JVM heap are out of scope (not Performance Tweaks).

**Baseline:** the only other 6.0.x image on hand is the UXG-Fiber 6.0.5 EA from the previous round (6.0.5 was never released for the UCG-Fiber). That is a cross-platform comparison, but the 6.0.5 round proved the SSDK code is platform-independent (UXGF 5.1.26 `.text` byte-identical to the UCGF 5.1.29 lineage), so it is a valid baseline for the module analysis. It is **not** a clean baseline for a whole-image diff, and none was attempted: the package adds/removes between the two are platform (MongoDB, PostgreSQL, the Network app, the LCD driver on the UCG-Fiber; the recovery/GPIO packages on the UXG-Fiber).

## Kernel

Build string from the FIT image: `Linux version 5.4.213-ui-ipq9574 (bdd@builder) (gcc version 14.2.0 (Debian 14.2.0-19)) #5.4.213 SMP PREEMPT Wed Sep 2 14:15:50 CST 2026`. The kernel was **rebuilt again** (6.0.5 was `Tue Aug 25 15:31:18 CST 2026`), but `uname -r` is still `5.4.213-ui-ipq9574` and the module **vermagic is unchanged**: `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`. The repo modules match it, so no rebuild is needed. 362 `.ko` in the image (6.0.5 UXGF had 360; the difference is platform, see below).

Modules live at `usr/lib/modules/5.4.213-ui-ipq9574/` (`lib` is a symlink to `usr/lib` on trixie), same as 6.0.5.

## qca-ssdk: code-identical to 6.0.5

`qca-ssdk.ko` (3,445,888 bytes) md5 = `3a7adcea48e6ff5c8dbf36d22cf353ea`. The md5 differs from 6.0.5 but the code does not:

| Comparison vs 6.0.5 UXGF (`151a68f1…`) | Result |
|---|---|
| Whole file (`cmp -l`) | **40 bytes differ** |
| Where | 20 in `.note.gnu.build-id`, 12 in `.rodata.str`, 8 in `.rodata.str1.1` |
| Raw `.text` (`objcopy --only-section=.text`, `cmp`) | **byte-identical**, md5 `c0c9d9551d9c843d0ad80e0db7d74e24`, 982,340 bytes both |
| `.text` / `.data` / `.bss` sizes | `0xefd44` / `0x191f8` / `0x10578`, identical |
| Symbol table (`nm`, unique names) | 9,353 vs 9,353, **zero delta** |

The 20 string bytes are the Jenkins job id embedded in the kernel-headers path (`debfactory_master/2878-12YB` in 6.0.7 vs `2856-34P0` in 6.0.5). Same compiler (`GCC: (Debian 14.2.0-19) 14.2.0`). So 6.0.7 is the same SSDK source, same toolchain, relinked into a new build: exactly the 5.1.26-style provenance-only delta, now in the 6.0.x line.

| Version | md5sum | size | vs reference |
|---|---|---|---|
| 5.1.26 → 5.1.31 (UCGF) | 8033a7fad2fd93eec8173f196d351dc1 | 3,456,424 | GCC 10 build |
| 6.0.5 EA (UXGF) | 151a68f1b2645f45a36aec95084772e6 | 3,445,888 | GCC 14 recompile, ABI intact |
| **6.0.7 (UCGF)** | **3a7adcea48e6ff5c8dbf36d22cf353ea** | **3,445,888** | **`.text` byte-identical to 6.0.5** |

### Symbols and offsets

All 10 symbols the module needs are present (2 linked externs, 8 via `kallsyms_lookup_name`): `adpt_hppe_uniphy_mode_set`, `_adpt_hppe_port_interface_mode_set`, `ssdk_dt_global_set_mac_mode`, `qca_ssdk_port_bmp_get`, `qca_ssdk_port_bmp_set`, `ssdk_phy_priv_data_get`, `ssdk_port_link_notify`, `ubnt_send_phy_event`, `ssdk_mac_sw_sync_work_stop`, `ssdk_mac_sw_sync_work_start`. The wider uniphy/sgmii/psgmii/usxgmii family is **114 symbols**, same as 6.0.5 and every 5.1.x build.

**The `0x690`/`0x6d0` speed and duplex cache offsets are unchanged.** `sfp_read_status` carries the same encodings at the same addresses as 6.0.5:

```
6.0.7    ca478: b9469040   ldr w0, [x2, #1680]   ; 0x690  speed cache
         ca480: b946d040   ldr w0, [x2, #1744]   ; 0x6d0  duplex cache
6.0.5    ca478: b9469040
         ca480: b946d040
```

`adpt_hppe_port_phy_status_change` still references both offsets. Since 6.0.5 corroborated these offsets live (`port bitmap 0x62 -> 0x42`, `speed cache 1000 -> 2500` read back sane prior values), and the 6.0.7 `.text` is byte-identical, the module's assumptions hold by construction.

### The rest of the module set

Of the 359 modules common to both images, **every one is `.text`-identical**. 32 differ at the file level, all by provenance: most by 20 to 230 bytes (build-id plus job-id string), and five (`ecm.ko`, `t_miner.ko`, `udx_poe_rtl.ko`, `udx_poe_class.ko`, `wireguard.ko`) by a few KB in non-code sections with identical `.text`. The UCG-Fiber adds `st7735fb.ko` (LCD), `ui-hdd-pwrctl.ko` and `ui_st_accel.ko`; the UXG-Fiber has `gpiodev.ko` instead. Platform, not version.

### About the 6.0.7 SFP release notes

The UCG-Fiber 6.0.7 release notes list "Improved SFP negotiation speed" and "Improved 1 Gbps link reliability when using the UACC-CM-RJ45-MG SFP module". Neither lives in `qca-ssdk.ko`: its code, including the fake "QCA SFP" PHY driver (`sfp_read_status`) the tweak depends on, is byte-identical to 6.0.5. `qca-nss-dp.ko` is `.text`-identical too. That leaves two places for those changes:

- **The rebuilt kernel image** (in-kernel `sfp`/`phylink` code), which was not diffed against 6.0.5 this round.
- **Userland that drives SFP ports**: `unifi-hal` (`1.0.0-1386+gfdd043a6d992` → `1.0.0-10+g83bde6877ddf`), `udapi-server`/`libudapi` (`g28a2a121ae5b` → `g181a028bd01e`) and `ubnt-tools` (`6.0.17` → `6.0.19`) all changed between 6.0.5 and 6.0.7. `qca-ssdk-shell` is the same git revision (`e690d0d7911c`), only its build number moved.

The module's static contract (symbols, struct offsets, port bitmap semantics) is intact, so it will load and resolve. What the static analysis cannot rule out is a **behavioral** interaction: if the userland or kernel now renegotiates SFP ports differently or more often, the forced SGMII+ mode could be re-applied or contested at a different point in the link sequence. That is a live-test question, and it makes the UCG-Fiber live check for 6.0.7 more important than for a typical patch release. Watch specifically for the `dmesg` sequence reappearing after link flaps and for `ethtool` holding 2500Mb/s across a cable re-seat.

## Userland

Still Debian 13.6 trixie, same generation as 6.0.5:

| | 6.0.5 (UXGF) | 6.0.7 (UCGF) |
|---|---|---|
| GCC (module builds) | 14.2.0-19 | 14.2.0-19 |
| Python | 3.13.5 | 3.13.5 (`3.13.5-2+deb13u4`) |
| systemd | 257 | 257.13-1~deb13u1 |
| syslog-ng | 4.8.1 | 4.8.1-5+deb13u1 |
| nginx | 1.30.4 | 1.30.4 |
| libc6 | 2.41 | 2.41-12+deb13u3 |
| OpenSSL | 3.5.6 | 3.5.7-1~deb13u2 |
| unifi-core | — | 6.0.104 |
| MongoDB | none (platform) | 3.6.23-ubnt+deb13u1 |
| dpkg packages | 530 | 582 |

Of the 520 packages common to both images, 16 changed version between 6.0.5 and 6.0.7: `base-files-deps-*` (6.0.79 → 6.0.85), OpenSSL (3.5.6 → 3.5.7), `libubnt`/`mcagent`, `libudapi`/`udapi-server`, `ubnt-igmp-snooping`/`ubnt-loopd`, `ubnt-tools` (6.0.17 → 6.0.19), `ubntnas`, `unifi-hal`, `ustd` (6.0.4 → 6.0.6) and the `qca-ssdk-shell` build number. The identity/credential stack is unchanged from 5.1.31 (`ucs-agent 1.8.4+2012`, `unifi-credential-server 1.8.4+4017`, `unifi-directory 2.7.4+470`). `python3.9` is gone entirely, as on 6.0.5.

## Boot Tweak Userland (static presence check against extracted rootfs)

### 06 + 07 — MongoDB SSD offload/backup ✓ (first 6.0.x check)

This is the first 6.0.x image with MongoDB in it (the UXG-Fiber ships none), so it is the first time 06+07 could be checked on the trixie userland. Everything the scripts assume is present and unchanged:

- `/usr/bin/mongod` (3.6.23, 44.8 MB), `mongodump`, `mongorestore`; `/usr/lib/unifi/bin/mongod` is now a symlink to `/usr/bin/mongod`.
- `unifi.service` and `unifi-mongodb.service` both present and enabled. Script 06 stops `unifi-mongodb.service` when it exists, which it does.
- `/etc/default/unifi` sets `UNIFI_MONGODB_DATA_DIR=/data/unifi/data/db`, matching script 06's `EMMC_DB_DIR`, and the unit runs `mongod --dbpath ${UNIFI_MONGODB_DATA_DIR} --port 27117`, matching script 07's `mongodump --port 27117`. `ExecStop` is a clean `mongod --shutdown`.
- The unit's `ExecStartPre` helpers (`unifi-mongo-service-helper ensure-directory-per-db` / `create-dirs` / `check-repair`) and `UNIFI_MONGODB_PREFER_DIRECTORY_PER_DB=true` operate on the dbpath, which is the bind-mount target; script 06 bind-mounts the SSD copy over `/data/unifi/data/db` before `unifi` starts, so the helpers see the SSD-backed directory. Whether these helpers are new in 6.0.x or carried over from 5.1.31 was not established (no 5.1.31 rootfs on hand this round).
- Shared userland: `ubnt-device-info`, `findmnt`, `mountpoint`, `tar`, `gzip`, `logger` all present.

### 10 — journald volatile ✓

Stock `journald.conf` ships `Storage=persistent` / `ForwardToSyslog=yes` (the script will flip both). syslog-ng 4.8.1 with the same `conf.d` layout: 15 config files, 12 of which declare local `file("/var/log...")` destinations outside `ulog`, which is the set the script comments out. `/etc/default/syslog-ng-persist` is present with the stock `--persist-file=/var/log/.syslog-ng.persist`, which the script redirects to tmpfs. All identical in shape to what script 10 handled live on 6.0.5.

### 15 — fan control ✓ with one caveat

`uhwd.service` + `/usr/sbin/uhwd` present, `python3` → 3.13.5, and the SDB client is at the unchanged import path (`ustd/statusdb/sdb_client.cpython-313-aarch64-linux-gnu.so`).

**Caveat:** `ustd` moved 6.0.4 → 6.0.6 and both `sdb_client…so` (md5 `5972f32f…` → `34462f1b…`) and `uhwd` changed. Script 15 uses only `SDBClient().run()`, `.get("config.fan")` and `.update("config.fan", …)`. The Cython 3.1 build compresses its string table, so the method names cannot be confirmed from `strings`, and an attempt to import the module under a qemu-user chroot on the RE host did not complete (see Outstanding). The risk is low, since this is the client's most basic API and 6.0.5's `ustd 6.0.4` build of the same cpython-313 module worked live, but it is unconfirmed until a live run logs `BEFORE`/`AFTER` setpoints.

### 19 + 20 — SFP SGMII+ ✓

`/usr/sbin/insmod` present.

## Conclusion

**6.0.7 is statically compatible on the UCG-Fiber.** `qca-ssdk.ko` is `.text`-byte-identical to the live-verified 6.0.5 SSDK (40 whole-file bytes differ, all build provenance), every other common kernel module is `.text`-identical, vermagic is unchanged, and all 10 symbols, the 114-symbol uniphy family and the `0x690`/`0x6d0` cache offsets are intact. All four deployed Performance Tweaks have their userland present, and this is the first 6.0.x image on which 06+07 could be checked at all.

The one thing static analysis cannot settle is the release-note SFP negotiation change, which is outside the SSDK and could in principle interact with the forced SGMII+ mode at runtime. Live verification on a UCG-Fiber running 6.0.7 is the next step and should be done on the lab box before any production deploy.

### Outstanding

- **Live check on a UCG-Fiber on 6.0.7** (lab box first): full `dmesg` sequence, `ethtool` at 2500Mb/s held across a link flap and cable re-seat, `rmmod` revert path, and 06+07+10+15 in effect after the upgrade's config reset.
- **Kernel image diff 6.0.5 → 6.0.7** to localize the SFP negotiation change (both FIT images are on the RE host).
- **SDB client API confirmation** for script 15 on `ustd 6.0.6` (live, or a working qemu-user chroot).
- **UCGF 5.1.31 → 6.0.7 image diff** for a same-platform account of the trixie rebase. Needs the 5.1.31 `.bin` re-downloaded; it is no longer on the RE host.
- `force_uniphy2_sgmiiplus.ko` untested on 6.0.x.

Reference `.ko` stored as `research/qca-ssdk-compare/qca-ssdk-6.0.7.ko`.
