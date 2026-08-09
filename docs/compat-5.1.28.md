# UniFi OS 5.1.28 EA Compatibility Verification

Verified 2026-08-01 (UTC). Firmware `UCGF-5.1.28` (build string `UCGF.ipq9574.v5.1.28.baa7152.260727.2115`) was downloaded and analyzed statically on the RE host (`root@nas`); nothing was run on a gateway. The release `.bin` (`33f5-UCGF-5.1.28-96a5fb04-...bin`, md5 `c827bfc20dec524ad94a9bb8d34898ad`) carries a zstd squashfs rootfs (`PARTrootfs`, 940,890,619 bytes) carved from offset `0xC57706`.

**Scope:** SGMII+ kernel module (static) and the userland surface the deployed Performance Tweaks depend on (MongoDB SSD offload/backup 06+07, journald volatile 10, fan control 15). This began as a **static / bench** round; 5.1.28 has **since been field-confirmed working on the UCG-Fiber** — the SGMII+ SFP+ module and all four boot tweaks run fine (user reports + our own gateways). Our UXG-Fiber (the longest-running SGMII+ box) is still on 5.1.26, so it is not part of the 5.1.28 evidence. That confirmation is operational, not instrumented: no UTC-bracketed lab load/unload, `dmesg` SGMII+ sequence, or `/proc/kallsyms` address was captured. Adaptive SQM and JVM heap are out of scope (not Performance Tweaks).

**Field status (2026-08-08):** operational on the UCG-Fiber — all four tweaks (06+07+10+15) plus the SGMII+ module run fine (which has the SSD + MongoDB that 06+07 require). The UXG-Fiber has not gone past 5.1.26, so 5.1.28 field evidence is UCG-Fiber only. Only outstanding item is formal lab instrumentation (captured `dmesg`/`kallsyms`).

## Kernel & qca-ssdk

- `uname -r` = `5.4.213-ui-ipq9574` — **unchanged** from 5.0.10 / 5.1.12 / 5.1.15 / 5.1.19 / 5.1.21 / 5.1.26 (confirmed in the extracted rootfs `lib/modules/5.4.213-ui-ipq9574/`). Module vermagic matches; no rebuild needed.
- `qca-ssdk.ko` (3,456,424 bytes) md5 = `8033a7fad2fd93eec8173f196d351dc1` — **byte-identical to 5.1.26** (`cmp` clean against the stored 5.1.26 reference). 5.1.26 was previously verified code-identical to 5.1.19/5.1.21 (`.text` byte-identical, zero disassembly diff, all 10 symbols + `0x690`/`0x6d0` offsets intact). So the SSDK is unchanged across all of 5.1.19 → 5.1.28, and every symbol and cache offset the module depends on is intact by construction.

| Version | md5sum | vs reference |
|---|---|---|
| 5.1.15 | 8b6799b7c4ada78c389b8b8381ad6b4a | `.text`-identical to 5.1.12 |
| 5.1.19 | dd7911587eae837dcf0ffef30fa5be62 | `.text`-identical to 5.1.15 |
| 5.1.21 EA | dd7911587eae837dcf0ffef30fa5be62 | byte-identical to 5.1.19 |
| 5.1.26 EA | 8033a7fad2fd93eec8173f196d351dc1 | `.text`-identical to 5.1.19/5.1.21 (md5 differs: build provenance only) |
| 5.1.28 EA | 8033a7fad2fd93eec8173f196d351dc1 | **byte-identical to 5.1.26** |

The 5.1.28 `.ko` also differs from the 5.1.19 reference at exactly the same first byte (offset 81) as 5.1.26 did — i.e. the same build-provenance bytes (build-id + embedded build timestamp + Jenkins job-id path string), none in code. Because 5.1.28 == 5.1.26 byte-for-byte, that characterization carries over verbatim; see [compat-5.1.26.md](compat-5.1.26.md) for the byte-level breakdown.

## SGMII+ Module Load Readiness

Both repo modules — `force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.ko` and `force-uniphy2-sgmiiplus/force_uniphy2_sgmiiplus.ko` — carry vermagic `5.4.213-ui-ipq9574`, matching the firmware kernel. Combined with the byte-identical qca-ssdk, the modules will `insmod` and resolve on 5.1.28 without a rebuild.

**Field-confirmed operational; formal lab capture still outstanding.** 5.1.28 is reported working in the field on the UCG-Fiber (SGMII+ module + boot tweaks, user reports + our own gateways) — the practical live gap is closed (our UXG-Fiber is still on 5.1.26, so it is not 5.1.28 evidence). What was *not* captured is instrumented evidence: to formally close that out on a future box, exercise the module per SOP (manual `insmod`/`rmmod` on an empty/down port, UTC-bracketed, live trunk watched) and confirm the `dmesg` pr_info sequence (`resolved all symbols` → `port bitmap 0x62 -> 0x42` → `uniphy1 set to SGMII+ 2.5G` → `speed cache ... -> 2500`). Note `clk_rate` is not a mode discriminator on 5.1.19+; verify via `dmesg`, not clock rate.

## Boot Tweak Userland (static presence check against extracted rootfs)

With no live 5.1.28 box, the live "in effect" check is replaced by confirming each tweak's userland surface still exists in the 5.1.28 rootfs. All present, identical to 5.1.26:

- **06+07 — MongoDB SSD offload/backup ✓** — `/usr/bin/mongod` (+ `/usr/lib/unifi/bin/mongod`), `ubnt-device-info`, `findmnt`, `mountpoint`, `tar`, `gzip`, `logger`, and both `unifi.service` + `unifi-mongodb.service` units are present.
- **10 — journald volatile ✓** — `/etc/systemd/journald.conf`, the `/etc/syslog-ng/conf.d/*.conf` set (15 files), and the `syslog-ng.service` + `systemd-journald.service` units are present.
- **15 — fan control ✓** — `uhwd.service` + `/usr/sbin/uhwd`, `python3.9`, and the SDB client are present. As on 5.1.26 the SDB client ships as a compiled extension (`ustd/statusdb/sdb_client.cpython-39-aarch64-linux-gnu.so`); the script's `from ustd.statusdb.sdb_client import SDBClient` import path is unchanged, so script 15 is unaffected.
- **19+20 — SFP SGMII+ ✓** — `/sbin/insmod` present.

The `on_boot.d` runner (`udm-boot`) is deployed alongside the scripts by NetworkOptimizer and is not part of stock firmware — its absence from the rootfs is expected, not a compatibility gap.

## Conclusion

UniFi OS 5.1.28 EA is **statically compatible**. The SGMII+ module is guaranteed by construction: the kernel is unchanged and `qca-ssdk.ko` is **byte-identical to the verified 5.1.26 SSDK** (which is itself code-identical to 5.1.19/5.1.21), so all 10 symbols and both cache offsets are intact. All four deployed Performance Tweaks (06+07+10+15) have their userland dependencies present in the 5.1.28 rootfs, and 5.1.28 is now **field-confirmed working on the UCG-Fiber** (SGMII+ module + boot tweaks, per user reports and our own gateways; our UXG-Fiber remains on 5.1.26). The only outstanding item is captured lab diagnostics — a UTC-bracketed SGMII+ load/unload with `dmesg`/`kallsyms` — which were not taken during operational use.
