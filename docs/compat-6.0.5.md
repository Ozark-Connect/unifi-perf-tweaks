# UniFi OS 6.0.5 Compatibility Verification

Verified 2026-09-03 (UTC), **live on a production UXG-Fiber**. Firmware `UBNTUXGA6AA.ipq9574.v6.0.5.0b3cb18.260825.1528` (built 2026-08-25), `.bin` md5 `5246412bbc2a978a2e59a97ae5ffc794`, zstd squashfs rootfs (334,917,068 bytes, 22,608 inodes) carved from offset `16038490`.

**6.0.5 EA has not been released for the UCG-Fiber.** The UXG-Fiber got it first, reversing the usual order, so this is the first round with no UCGF baseline available.

**Scope:** live SGMII+ module and boot tweaks 10 + 15, plus a static release-image check. **06 + 07 (MongoDB SSD) are unverified** — the UXG-Fiber ships no MongoDB at all. Adaptive SQM and JVM heap are out of scope (not Performance Tweaks). Gateway actions were read-only and UTC-bracketed; all binary analysis ran on the RE host against the pulled `.ko` and extracted rootfs.

## What changed in 6.0.x

A major release, not a maintenance patch. The userland rebases Debian 11 → 13:

| | 5.1.31 (bullseye) | 6.0.5 (trixie) |
|---|---|---|
| Debian | 11 | **13** (13.6) |
| GCC (module builds) | 10.2.1 | **14.2.0** |
| Python | 3.9 | **3.13.5** |
| systemd | 247 | **257** |
| syslog-ng | 3.x | **4.8.1** |
| nginx | 1.30.4 | 1.30.4 |
| SDB client | `cpython-39` `.so` | `cpython-313` `.so` (same import path) |

`/var/log` is a dedicated ext4 partition (`/dev/mmcblk0p4`, 974M) with `/var/log/ulog` on tmpfs. Still eMMC-backed, so tweak 10's rationale is unchanged.

## Kernel

`uname -r` is still `5.4.213-ui-ipq9574`, but the kernel was **rebuilt** (`#5.4.213 SMP PREEMPT Tue Aug 25 15:31:18 CST 2026`). **vermagic is unchanged** (`5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`), so the prebuilt repo modules load without a rebuild. Proven live, not inferred. 360 `.ko` in the image.

## qca-ssdk: changed, but ABI-compatible

`qca-ssdk.ko` changed for the first time since 5.1.19. Live gateway and release image agree exactly.

| Version | md5sum | size |
|---|---|---|
| 5.1.19 / 5.1.21 EA (UCGF) | dd7911587eae837dcf0ffef30fa5be62 | 3,456,424 |
| 5.1.26 → 5.1.31 (UCGF) | 8033a7fad2fd93eec8173f196d351dc1 | 3,456,424 |
| 5.1.26 EA (UXGF) | 0ecd2fea0cb79988ec94dfef08a52619 | 3,456,424 |
| **6.0.5 EA (UXGF)** | **151a68f1b2645f45a36aec95084772e6** | **3,445,888** |

**The change is a compiler change, not a source change.** From `.comment`:

| Build | Compiler |
|---|---|
| 5.1.29 SSDK | `GCC: (Debian 10.2.1-6) 10.2.1 20210110` |
| 6.0.5 SSDK | `GCC: (Debian 14.2.0-19) 14.2.0` |

That is the bullseye → trixie toolchain jump, and it accounts for the whole delta:

- `.text` 987,816 → 982,852 bytes (better inlining).
- **The entire symbol delta is GCC clone-name churn**: `.isra.0` ↔ `.constprop.0` swaps, inlining decisions, `CSWTCH.N` switch-table renumbering. 9,181 unique names vs 9,187. No functional API appears or disappears.
- `.data` (102,904) and `.bss` (66,936) are identical in size, so static struct layouts did not move.

### Platform is not a factor

Every pre-6.0 reference `.ko` was carved from a UCG-Fiber image, so the md5 change could in principle have been "UXGF vs UCGF" rather than "6.0.5 vs 5.1.x". A **UXGF 5.1.26** image (the UXG-Fiber's last 5.1.x before it jumped to 6.0.x) settles it, and rules platform out:

| Comparison | Raw `.text` |
|---|---|
| UXGF 5.1.26 vs UCGF 5.1.29 (cross-platform, same era) | **byte-identical** (md5 `f0a20aca…`, 986,792 bytes both) |
| UXGF 5.1.26 vs UXGF 6.0.5 (same platform) | **864,912 differing bytes** |

UXGF 5.1.26 differs from the UCGF lineage in only **36 whole-file bytes**, all build provenance: `.note.gnu.build-id` plus two embedded build strings. Same compiler (GCC 10.2.1), byte-identical code, identical `sfp_read_status` encodings at the identical address, 114 uniphy/sgmii symbols, 10/10 required symbols. So the SSDK code is platform-independent across UCG-Fiber and UXG-Fiber, and the 6.0.5 delta is entirely the version/toolchain change.

### Symbols and offsets

All 10 symbols the module needs are present in the 6.0.5 `.ko` (2 linked externs, 8 via `kallsyms_lookup_name`), and the wider uniphy/sgmii/psgmii/usxgmii family is **114 symbols in both** builds.

**The `0x690`/`0x6d0` speed and duplex cache offsets are unchanged.** `sfp_read_status` — the fake "QCA SFP" PHY driver whose `phydev->speed` copy the tweak depends on — carries byte-identical instruction encodings:

```
6.0.5    ca478: b9469040   ldr w0, [x2, #1680]   ; 0x690  speed cache
         ca480: b946d040   ldr w0, [x2, #1744]   ; 0x6d0  duplex cache
5.1.29   cb540: b9469040   ldr w0, [x2, #1680]
         cb548: b946d040   ldr w0, [x2, #1744]
```

`adpt_hppe_port_phy_status_change` still references both offsets too.

## SGMII+: live confirmed

The repo module loaded at boot on 6.0.5 with the full expected sequence:

```
[Thu Sep  3 08:55:32 2026] force_sgmiiplus: resolved all symbols
[Thu Sep  3 08:55:32 2026] force_sgmiiplus: port bitmap 0x62 -> 0x42 (port 5 excluded)
[Thu Sep  3 08:55:32 2026] force_sgmiiplus: uniphy1 set to SGMII+ 2.5G
[Thu Sep  3 08:55:33 2026] force_sgmiiplus: loop restarted (port 5 excluded)
[Thu Sep  3 08:55:33 2026] force_sgmiiplus: speed cache 1000 -> 2500
[Thu Sep  3 08:55:33 2026] force_sgmiiplus: speed reporting updated
```

Two of those lines are the offset-dependent operations, and both read back sane prior values (`0x62`, the stock bitmap; `1000`, the SGMII 1G speed). Had the struct layout shifted, they would have read garbage. That independently corroborates the static offset finding.

Datapath confirmed working, not just configured:

- `ethtool eth6`: **2500Mb/s, Full, link detected**.
- `eth6` counters: 2,641,019,070 bytes / 2,338,804 packets rx and 2,505,199,867 / 2,228,487 tx, **zero errors, drops, and carrier errors**. This is the live Calix ONT WAN.
- `eth0`–`eth5` unaffected, all still 10000Mb/s (including the eth5 SFP+ trunk).
- Loaded `.ko` md5 `bbd0a2c9b9abe0c8e7d544f0e9b022b9` is **byte-identical to the repo artifact**.

### kallsyms capture

Every round since 5.1.26 carried "no captured `dmesg`/kallsyms" as outstanding. 6.0.5 closes it. With the module loaded, all ten resolved (`kptr_restrict=0`):

| Symbol | Address | |
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

`adpt_hppe_uniphy_mode_set` moved from `ffffffc00894f200` (5.1.19/5.1.21), which is exactly why the module resolves by name rather than hardcoding addresses. Module mapped at `ffffffc0091da000`.

**Not exercised:** the `rmmod` revert path, since `eth6` is this gateway's live WAN. `force_uniphy2_sgmiiplus.ko` (md5 `6af250aaf44d12ead5ed64a0940ec287`) is untested on 6.0.5 but shares the same vermagic, symbols, and offsets.

## Boot tweaks

The upgrade reset stock config in two places and both tweaks re-applied on the post-upgrade boot, same pattern as the 5.1.21 upgrade. `udm-boot.service` finished `status=0/SUCCESS` with no tweak errors.

### 15 — fan control ✓

From `/var/log/fan-control-tuning.log`:

```
BEFORE: setpoints={"cpu": 100, "rtl8372": 109, "rtl8261": 103} standby=20
AFTER:  setpoints={"cpu": 65, "rtl8372": 85, "rtl8261": 90} standby=20
```

Live SDB read-back confirms it held. Fan at 1931 RPM / pwm 38, sensors 56.2–60.4 °C. The UXG-Fiber has no `hdd` PID category (no drive), which the script's `if "hdd" in pid` guard handles.

**The Python jump is a non-issue here, but only just.** `python3.9` is gone (`python3` → 3.13.5) and the SDB client is now `cpython-313`. Script 15 calls plain `python3` and imports `from ustd.statusdb.sdb_client import SDBClient`; both the symlink and the import path are unchanged. A version-pinned `python3.9` call would have broken.

### 10 — journald volatile ✓

Stock 6.0.5 ships `Storage=persistent` / `ForwardToSyslog=yes`, and the upgrade replaced all of `/etc/syslog-ng/conf.d`. Script 10 re-disabled local eMMC log routes in **11 config files** and restarted syslog-ng. Live state:

- `journald.conf`: `Storage=volatile`, `ForwardToSyslog=no`.
- Journal is RAM-only: `/run/log/journal` 8.9M, `/var/log/journal` empty.
- Persist file on tmpfs (`--persist-file=/run/syslog-ng.persist`).
- Remote syslog and tmpfs destinations intact by design.

This works **despite syslog-ng 3.x → 4.8.1** (`4.8.1-5+deb13u1`): the `conf.d` layout, the `log { ... }` route syntax the script comments out, and `/etc/default/syslog-ng-persist` are all unchanged. This was the round's largest userland risk.

Script 10 logs via `logger` to the journal rather than to a file on eMMC, which is why there is no `/var/log/journald-volatile.log`. By design, not a failure.

### 06 + 07 — MongoDB SSD ✗ not verified

Unverifiable on this platform. 6.0.5 for UXG-Fiber ships **no MongoDB and no Network app at all** — `mongod`, `mongodump`, `mongorestore`, `unifi.service`, and `unifi-mongodb.service` are absent both live and in the release rootfs. A UXG-Fiber platform trait, not a 6.0.5 regression. The shared userland these scripts also need is present (`ubnt-device-info`, `findmnt`, `mountpoint`, `tar`, `gzip`, `logger`).

### 19 + 20 — SFP SGMII+ ✓

`insmod` present.

## Conclusion

**6.0.5 is compatible on the UXG-Fiber, field-confirmed.** The SGMII+ module loads, the 2.5G datapath carries production WAN traffic error-free, and tweaks 10 and 15 are verified in effect after correctly re-applying over the upgrade's config reset.

`qca-ssdk.ko` changed for the first time since 5.1.19, but it is a GCC 10 → 14 recompile with an unchanged ABI: all 10 symbols present, 114 uniphy/sgmii symbols, identical `.data`/`.bss` sizes, a symbol delta that is pure compiler churn, and cache offsets confirmed by byte-identical `sfp_read_status` encodings then corroborated live. A UXGF 5.1.26 control rules out any platform contribution. vermagic is unchanged, so no rebuild is needed.

Notably, the trixie rebase moved Python 3.9 → 3.13 and syslog-ng 3.x → 4.8.1 without breaking either script that touches them, because both depend on stable surfaces.

### Outstanding

- **UCG-Fiber on 6.0.5**, blocked upstream: 6.0.5 EA is not released for it. Note this is now a coverage gap only, not an analytical one — the UXGF 5.1.26 comparison above rules platform out, so the SSDK findings carry over.
- **06 + 07**, needs a UCG-Fiber or UDM-SE on 6.0.5.
- **Unload/revert path** and **`force_uniphy2_sgmiiplus.ko`**, need a lab box.
- **No release image diff.** A clean one needs a same-platform baseline (a UXGF 5.1.x image); the 5.1.31 reference is UCGF, so cross-platform would be noise.

**Closed this round:** the `dmesg` + kallsyms capture outstanding since 5.1.26. 6.0.5 is the first version since 5.1.21 with both recorded.

Reference `.ko` stored as `research/qca-ssdk-compare/qca-ssdk-6.0.5.ko`.
