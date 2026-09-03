# UniFi OS 6.0.5 Compatibility Verification

Verified 2026-09-03 (UTC). **This is the first 6.0.x round, and it is a major-release check, not a maintenance one** — UniFi OS 6.0.5 rebases the userland from Debian 11 (bullseye) to **Debian 13 (trixie)**, which brings a new toolchain (GCC 10 → 14), Python 3.9 → 3.13, systemd 247 → 257, and syslog-ng 3.x → 4.8.1. `qca-ssdk.ko` changes for the first time since 5.1.19, ending the byte-identical streak that ran 5.1.26 → 5.1.31.

Platform: **UXG-Fiber** running 6.0.5 EA in production (upgraded 2026-09-03 08:53 local). Firmware `UBNTUXGA6AA.ipq9574.v6.0.5.0b3cb18.260825.1528` (built 2026-08-25), release `.bin` `c5c7-UXGA6AA-6.0.5-...bin`, md5 `5246412bbc2a978a2e59a97ae5ffc794`, carrying a zstd squashfs rootfs (`PARTrootfs`, 334,917,068 bytes, 22,608 inodes) carved from offset `16038490`.

**Scope:** this round is **live/field on a UXG-Fiber** for the SGMII+ module and boot tweaks 10 + 15, plus a static release-image check. Tweaks **06 + 07 (MongoDB SSD offload/backup) are out of scope and unverified** — the UXG-Fiber has no SSD and, as confirmed below, ships no MongoDB at all. Adaptive SQM and JVM heap remain out of scope (not Performance Tweaks).

This round is UXG-Fiber-only for a reason worth recording: **6.0.5 EA has not been released for the UCG-Fiber.** The UXG-Fiber got it first, which is a reversal of the usual order — the UCG-Fiber is our primary test platform and normally leads. Every previous compat round was anchored on a UCGF image, so this is the first round with no UCGF baseline available at all.

All gateway actions were read-only and UTC-bracketed. Binary analysis was done on the RE host (`root@nas`) against the pulled `.ko` and the extracted release rootfs — nothing was disassembled on the gateway.

## Kernel

- `uname -r` = `5.4.213-ui-ipq9574` — the version **string** is unchanged from 5.0.10 → 5.1.31, but the kernel was **rebuilt**: `#5.4.213 SMP PREEMPT Tue Aug 25 15:31:18 CST 2026`.
- Crucially, **vermagic is identical**: `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, confirmed in both the 6.0.5 `qca-ssdk.ko` and the repo's prebuilt modules. So no module rebuild is required — and this is proven live, not just inferred (see below).
- 360 `.ko` files in the release image.

## qca-ssdk — changed, but ABI-compatible

`qca-ssdk.ko` is **no longer byte-identical** to the 5.1.19 → 5.1.31 lineage. Live gateway and release image agree exactly:

| Version | md5sum | size | vs reference |
|---|---|---|---|
| 5.1.19 / 5.1.21 EA | dd7911587eae837dcf0ffef30fa5be62 | 3,456,424 | `.text`-identical to 5.1.15 |
| 5.1.26 EA | 8033a7fad2fd93eec8173f196d351dc1 | 3,456,424 | `.text`-identical (md5 differs: build provenance only) |
| 5.1.28 / 5.1.29 / 5.1.30 / 5.1.31 | 8033a7fad2fd93eec8173f196d351dc1 | 3,456,424 | byte-identical to 5.1.26 |
| **6.0.5 EA** | **151a68f1b2645f45a36aec95084772e6** | **3,445,888** | **`.text` fully recompiled** |

The live gateway's `/usr/lib/modules/5.4.213-ui-ipq9574/extra/qca-ssdk.ko` and the release image's copy are both md5 `151a68f1…`, so the running SSDK is stock.

### The change is a compiler change, not a source change

The `.comment` section settles it:

| Build | Compiler |
|---|---|
| 5.1.29 SSDK | `GCC: (Debian 10.2.1-6) 10.2.1 20210110` |
| 6.0.5 SSDK | `GCC: (Debian 14.2.0-19) 14.2.0` |

That is the bullseye → trixie toolchain jump, and it explains the whole delta:

- `.text` 987,816 → 982,852 bytes (slightly smaller — better inlining).
- **The entire symbol delta is GCC clone-name churn.** Every added/removed name is an optimization artifact: `.isra.0` ↔ `.constprop.0` swaps (e.g. `_adpt_hppe_acl_ipv4_fields_check`, `__adpt_hppe_policer_rate_to_refresh`), inlining decisions (`_adpt_gmac_port_rxfc_status_set` losing its suffix), and `CSWTCH.N` switch-table renumbering. Unique symbol names: 9,181 (6.0.5) vs 9,187 (5.1.29). **No functional API appears or disappears.**
- `.data` (102,904 bytes) and `.bss` (66,936 bytes) are **identical in size** — a strong signal that static struct layouts did not move.

### Every symbol and offset the SGMII+ module needs is intact

All 10 symbols resolve in the 6.0.5 `.ko` (2 linked `extern`, 8 via `kallsyms_lookup_name`):

| Symbol | 6.0.5 | 5.1.29 |
|---|---|---|
| `adpt_hppe_uniphy_mode_set` | ✓ | ✓ |
| `_adpt_hppe_port_interface_mode_set` | ✓ | ✓ |
| `ssdk_dt_global_set_mac_mode` | ✓ | ✓ |
| `qca_ssdk_port_bmp_get` | ✓ | ✓ |
| `qca_ssdk_port_bmp_set` | ✓ | ✓ |
| `ssdk_phy_priv_data_get` | ✓ | ✓ |
| `ssdk_port_link_notify` | ✓ | ✓ |
| `ubnt_send_phy_event` | ✓ | ✓ |
| `ssdk_mac_sw_sync_work_stop` | ✓ | ✓ |
| `ssdk_mac_sw_sync_work_start` | ✓ | ✓ |

The wider uniphy/sgmii/psgmii/usxgmii symbol family is **114 symbols in both**.

**The `0x690` / `0x6d0` speed and duplex cache offsets are confirmed unchanged**, and this is the strongest static result of the round. `sfp_read_status` — the fake "QCA SFP" PHY driver whose `phydev->speed` copy the tweak depends on — carries **byte-identical instruction encodings** in both builds:

```
6.0.5    ca478: b9469040   ldr w0, [x2, #1680]   ; 0x690  speed cache
         ca480: b946d040   ldr w0, [x2, #1744]   ; 0x6d0  duplex cache
5.1.29   cb540: b9469040   ldr w0, [x2, #1680]
         cb548: b946d040   ldr w0, [x2, #1744]
```

`adpt_hppe_port_phy_status_change` likewise still references both offsets. Despite a full recompile, the struct layout the module writes into did not move.

## SGMII+ Module — LIVE CONFIRMED on 6.0.5

This is the first 6.0.x round with live evidence, and it covers the load path end to end. The repo module loaded at boot on 6.0.5 and produced the complete expected `pr_info` sequence:

```
[Thu Sep  3 08:55:32 2026] force_sgmiiplus: resolved all symbols
[Thu Sep  3 08:55:32 2026] force_sgmiiplus: port bitmap 0x62 -> 0x42 (port 5 excluded)
[Thu Sep  3 08:55:32 2026] force_sgmiiplus: uniphy1 set to SGMII+ 2.5G
[Thu Sep  3 08:55:33 2026] force_sgmiiplus: loop restarted (port 5 excluded)
[Thu Sep  3 08:55:33 2026] force_sgmiiplus: speed cache 1000 -> 2500
[Thu Sep  3 08:55:33 2026] force_sgmiiplus: speed reporting updated
```

Two of those lines are the offset-dependent operations, and both read back sane pre-existing values — `port bitmap 0x62` (the expected stock bitmap) and `speed cache 1000` (the expected SGMII 1G value). That is independent live corroboration of the static offset finding: had the struct layout shifted, these would have read garbage.

Datapath confirmed working, not merely configured:

- `lsmod`: `force_uniphy1_sgmiiplus` loaded, with `qca_ssdk` holding a reference.
- `ethtool eth6`: **Speed 2500Mb/s, Duplex Full, Link detected: yes**.
- `eth6` counters at time of check: 2,641,019,070 bytes / 2,338,804 packets rx and 2,505,199,867 bytes / 2,228,487 packets tx, **zero errors, zero drops, zero carrier errors** — this is the live Calix ONT WAN path carrying production traffic.
- All other ports unaffected (`eth0`–`eth5` all still 10000Mb/s, including the eth5 SFP+ trunk).

### kallsyms capture — the long-standing gap is closed

Every round since 5.1.26 carried "no captured `dmesg`/kallsyms" as an outstanding item. **6.0.5 closes it.** With the module loaded, all ten symbols were read live from `/proc/kallsyms` (`kptr_restrict=0`):

| Symbol | Address | Type |
|---|---|---|
| `adpt_hppe_uniphy_mode_set` | `ffffffc008934488` | t |
| `_adpt_hppe_port_interface_mode_set` | `ffffffc00891fc08` | t |
| `ssdk_dt_global_set_mac_mode` | `ffffffc0089dcfdc` | t |
| `qca_ssdk_port_bmp_get` | `ffffffc0089713e0` | t |
| `qca_ssdk_port_bmp_set` | `ffffffc0089713c0` | t |
| `ssdk_phy_priv_data_get` | `ffffffc0089e1910` | t |
| `ssdk_port_link_notify` | `ffffffc0089ade38` | t |
| `ubnt_send_phy_event` | `ffffffc0089207a4` | t |
| `ssdk_mac_sw_sync_work_stop` | `ffffffc0089e1948` | T |
| `ssdk_mac_sw_sync_work_start` | `ffffffc0089e19a4` | T |

The eight `t` (local) symbols are the kallsyms lookups; the two `T` (global) symbols are the linked externs. `adpt_hppe_uniphy_mode_set` moved from `ffffffc00894f200` (5.1.19/5.1.21) to `ffffffc008934488` — the rebuilt kernel and recompiled SSDK shifted every address, which is precisely why the module resolves by name at runtime instead of hardcoding. The module itself is mapped at `ffffffc0091da000`.

The loaded module is **byte-identical to the repo artifact**: `/data/calix-sfp/force_uniphy1_sgmiiplus.ko` md5 `bbd0a2c9b9abe0c8e7d544f0e9b022b9` == `modules/force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.ko`. No rebuild was needed for 6.0.5.

**Not exercised:** the `rmmod` / unload-and-revert path. `eth6` is this gateway's live WAN, so unloading would drop production internet; the SOP load/unload cycle needs a lab box on 6.0.5. `force_uniphy2_sgmiiplus.ko` (md5 `6af250aaf44d12ead5ed64a0940ec287`) is untested on 6.0.5 but shares the same vermagic, symbols, and offsets, so it rests on the same evidence.

## Boot Tweaks — live verification

The 6.0.5 upgrade reset stock config in two places, and both tweaks correctly re-applied on the post-upgrade boot — the same pattern seen on the 5.1.21 upgrade. `udm-boot.service` finished `status=0/SUCCESS` with no tweak errors.

### 15 — fan control ✓ verified in effect

The upgrade reset the SDB fan config to stock; script 15 re-tuned it. From `/var/log/fan-control-tuning.log`:

```
2026-09-03 08:55:36 - uhwd.service is active (waited 0s)
BEFORE: setpoints={"cpu": 100, "rtl8372": 109, "rtl8261": 103} standby=20
AFTER:  setpoints={"cpu": 65, "rtl8372": 85, "rtl8261": 90} standby=20
2026-09-03 08:55:49 - uhwd.service restarted successfully
```

Live SDB read-back confirms `config.fan` PID setpoints `cpu=65`, `rtl8372=85`, `rtl8261=90`, `standby=20`, `calc_type=pid`. Fan at 1931 RPM / pwm 38, thermal sensors 56.2–60.4 °C.

**The trixie Python jump is a non-issue for this script, but it was worth checking.** `python3.9` is gone (`/usr/bin/python3` → `python3.13`, 3.13.5) and the SDB client is now `sdb_client.cpython-313-aarch64-linux-gnu.so` instead of `cpython-39`. Script 15 invokes plain `python3` and imports `from ustd.statusdb.sdb_client import SDBClient` — the interpreter symlink and the import path are both unchanged, so it works as-is. A version-pinned `python3.9` call would have broken here; ours is not.

Note the UXG-Fiber has **no `hdd` PID category** (no drive), so `HDD_SETPOINT` is simply not applied — the script's `if "hdd" in pid` guard handles this correctly.

### 10 — journald volatile ✓ verified in effect

Stock 6.0.5 ships `Storage=persistent` / `ForwardToSyslog=yes`, and the upgrade replaced the whole of `/etc/syslog-ng/conf.d` (mtimes 08:53–08:54). Script 10 did real work on the post-upgrade boot, re-disabling local eMMC log routes in **11 config files** (`auth`, `bash-history`, `cron`, `daemon`, `debug`, `error`, `kern`, `mail`, `messages`, `news`, `wan-diag`) and restarting syslog-ng.

Live state confirms it held:

- `/etc/systemd/journald.conf`: `Storage=volatile`, `ForwardToSyslog=no`.
- Journal is RAM-only: `/run/log/journal` 8.9M, `/var/log/journal` empty (4.0K).
- syslog-ng persist file on tmpfs: `SYSLOGNG_OPTS="--persist-file=/run/syslog-ng.persist"`, file present at `/run/syslog-ng.persist`.
- Remote syslog and tmpfs destinations intact as designed (`d_udapi_server_remote` routes still active; `/var/log/ulog` is tmpfs).

**This works despite syslog-ng jumping 3.x → 4.8.1** (`4.8.1-5+deb13u1`, config version 4.2) — the `conf.d` layout, the `log { ... }` route syntax the script comments out, and `/etc/default/syslog-ng-persist` are all unchanged, so the script's `sed`/`grep` approach still matches. This was the largest userland risk in the round and it came out clean.

Script 10 logs via `logger` to the journal (tagged `journald-volatile`) rather than to a file on eMMC, which is why there is no `/var/log/journald-volatile.log` — that is by design, not a failure. Deployed script md5 `17f91b1f1191a43fcdb1bef52780637a` matches the repo copy.

### 06 + 07 — MongoDB SSD offload/backup — NOT VERIFIED

Out of scope this round and genuinely unverifiable on this platform. The UXG-Fiber has no SSD, and 6.0.5 for UXG-Fiber ships **no MongoDB and no UniFi Network app at all** — confirmed both live and in the extracted release rootfs:

- Absent: `mongod`, `mongodump`, `mongorestore`, `/usr/lib/unifi/bin/mongod`, `unifi.service`, `unifi-mongodb.service`.

This is a UXG-Fiber platform trait, **not a 6.0.5 regression**. Verifying 06 + 07 on 6.0.5 requires a UCG-Fiber (or UDM-SE) on 6.0.5 — which is not yet possible, as 6.0.5 EA has not been released for the UCG-Fiber (see Outstanding). The shared userland these scripts also depend on is present: `ubnt-device-info`, `findmnt`, `mountpoint`, `tar`, `gzip`, `logger`.

### 19 + 20 — SFP SGMII+ ✓

`insmod` present at `/usr/sbin/insmod` (and `/sbin/insmod`) in both the live system and the release rootfs.

## Userland baseline change (6.0.x vs 5.1.x)

Worth recording, since it is the substance of the major-version bump and the thing future rounds will diff against:

| | 5.1.31 (bullseye) | 6.0.5 (trixie) |
|---|---|---|
| Debian | 11 | **13 (13.6)** |
| GCC (module builds) | 10.2.1 | **14.2.0** |
| Python | 3.9 | **3.13.5** |
| systemd | 247 | **257 (257.13-1~deb13u1)** |
| syslog-ng | 3.x | **4.8.1** |
| nginx | 1.30.4 | 1.30.4 (unchanged) |
| SDB client | `cpython-39` `.so` | `cpython-313` `.so` (same import path) |

`/var/log` is a dedicated ext4 partition (`/dev/mmcblk0p4`, 974M) with `/var/log/ulog` on tmpfs — still eMMC-backed, so the rationale for tweak 10 is unchanged.

## Conclusion

**UniFi OS 6.0.5 is compatible on the UXG-Fiber, field-confirmed.** The SGMII+ module loads and the 2.5G datapath is carrying production WAN traffic error-free, and boot tweaks 10 and 15 are verified in effect on a post-upgrade boot — both correctly re-applying after the upgrade reset stock config.

The headline is that `qca-ssdk.ko` changed for the first time since 5.1.19, but the change is fully explained: it is a **GCC 10 → 14 recompile** riding along with the Debian 11 → 13 rebase, with an unchanged ABI surface. All 10 required symbols are present, the uniphy/sgmii symbol family is unchanged at 114, `.data`/`.bss` sizes are identical, the symbol delta is entirely compiler clone-name churn, and the `0x690`/`0x6d0` cache offsets are confirmed by byte-identical `sfp_read_status` instruction encodings — then independently corroborated live by the module reading back `0x62` and `1000`. vermagic is unchanged, so the existing prebuilt modules load without a rebuild.

The other headline is that the trixie rebase moved Python 3.9 → 3.13 and syslog-ng 3.x → 4.8.1 without breaking either script that touches them, because both depend on stable surfaces (the `python3` symlink and the `ustd.statusdb.sdb_client` import path; the `conf.d` layout and route syntax).

### Outstanding

- **UCG-Fiber on 6.0.5 is not covered, and cannot be yet — 6.0.5 EA has not been released for the UCG-Fiber.** Unusually, the UXG-Fiber got this release first; normally the UCG-Fiber (our primary test platform) leads. So there is no UCGF 6.0.5 image to analyze, and the UCGF SSDK md5 for 6.0.x is simply unknown until Ubiquiti ships it. This also means the `151a68f1…` md5 change is, strictly speaking, confounded between "6.0.5 vs 5.1.31" and "UXGF vs UCGF", because every pre-6.0 reference `.ko` in `research/qca-ssdk-compare/` was carved from a UCGF image. The GCC 10 → 14 `.comment` evidence makes the toolchain explanation overwhelmingly likely, and none of the live results depend on resolving it. **The clean way to settle it without waiting for UCGF 6.0.5** is a UXGF **5.1.26** image (the UXG-Fiber's last 5.1.x before it jumped to 6.0.x): if its `qca-ssdk.ko` md5 is `8033a7fa…`, matching the UCGF 5.1.26 reference, then the SSDK is platform-independent and the 6.0.5 delta is purely a version/toolchain change.
- **Tweaks 06 + 07 unverified on 6.0.5** — needs an SSD-equipped UCG-Fiber or UDM-SE on 6.0.5.
- **Module unload/revert path not exercised** on 6.0.5 (production WAN rides `eth6`); needs a lab box.
- **`force_uniphy2_sgmiiplus.ko` untested** on 6.0.5 (rests on shared static evidence).
- **No full release image diff** for 6.0.5. A clean diff needs a same-platform baseline (a UXGF 5.1.x image); the existing 5.1.31 reference is UCGF, so a cross-platform diff would be noise.

**Closed this round:** the `dmesg` + kallsyms capture that had been outstanding since 5.1.26 (see above) — 6.0.5 is the first version since 5.1.21 with both recorded.

Reference `.ko` stored as `research/qca-ssdk-compare/qca-ssdk-6.0.5.ko`; firmware downloaded and expanded on the RE host.
