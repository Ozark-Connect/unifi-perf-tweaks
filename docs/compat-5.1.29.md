# UniFi OS 5.1.29 Compatibility Verification

Verified 2026-08-08 (UTC). Firmware `UCGF-5.1.29` (build string `UCGF.ipq9574.v5.1.29.c9479cc.260805.0939`) was downloaded and analyzed statically on the RE host (`root@nas`); nothing was run on a gateway. The release `.bin` (`9722-UCGF-5.1.29-0a47e45e-...bin`, md5 `88846f42a99b898c36f1d35bbef1b68b`) carries a zstd squashfs rootfs (`PARTrootfs`, 942,258,296 bytes) carved from offset `0xC56EB2`.

**Scope:** SGMII+ kernel module (static) and the userland surface the deployed Performance Tweaks depend on (MongoDB SSD offload/backup 06+07, journald volatile 10, fan control 15). This is a **static / bench-only** round — the field gateways are staying on older firmware for now, so the live SGMII+ load/unload and the "tweaks in effect" checks are deferred to a later deploy, same posture as the 5.1.26 / 5.1.28 rounds. Adaptive SQM and JVM heap are out of scope (not Performance Tweaks).

This round was done off the back of a full 5.1.28 → 5.1.29 image diff (see `research/firmware-diff-5.1.28-to-5.1.29.md`), which independently established that the kernel and **all 361 kernel modules are byte-identical** between 5.1.28 and 5.1.29 (5.1.29 is a userland patch release — nginx, unifi-core, and the agents bumped; no kernel/driver changes).

## Kernel & qca-ssdk

- `uname -r` = `5.4.213-ui-ipq9574` — **unchanged** from 5.0.10 / 5.1.12 / 5.1.15 / 5.1.19 / 5.1.21 / 5.1.26 / 5.1.28 (confirmed in the extracted rootfs `lib/modules/5.4.213-ui-ipq9574/`). Module vermagic matches; no rebuild needed.
- `qca-ssdk.ko` (3,456,424 bytes) md5 = `8033a7fad2fd93eec8173f196d351dc1` — **byte-identical to 5.1.26 / 5.1.28** (`cmp` clean against the stored reference; also confirmed by the 5.1.28→5.1.29 module diff showing zero `.ko` changed). 5.1.26 was previously verified code-identical to 5.1.19/5.1.21 (`.text` byte-identical, zero disassembly diff, all 10 symbols + `0x690`/`0x6d0` offsets intact). So the SSDK is unchanged across all of 5.1.19 → 5.1.29, and every symbol and cache offset the module depends on is intact by construction.

| Version | md5sum | vs reference |
|---|---|---|
| 5.1.19 | dd7911587eae837dcf0ffef30fa5be62 | `.text`-identical to 5.1.15 |
| 5.1.21 EA | dd7911587eae837dcf0ffef30fa5be62 | byte-identical to 5.1.19 |
| 5.1.26 EA | 8033a7fad2fd93eec8173f196d351dc1 | `.text`-identical to 5.1.19/5.1.21 (md5 differs: build provenance only) |
| 5.1.28 EA | 8033a7fad2fd93eec8173f196d351dc1 | byte-identical to 5.1.26 |
| 5.1.29 | 8033a7fad2fd93eec8173f196d351dc1 | **byte-identical to 5.1.26 / 5.1.28** |

## SGMII+ Module Load Readiness

Both repo modules — `force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.ko` and `force-uniphy2-sgmiiplus/force_uniphy2_sgmiiplus.ko` — carry vermagic `5.4.213-ui-ipq9574`, matching the firmware kernel. Combined with the byte-identical qca-ssdk, the modules will `insmod` and resolve on 5.1.29 without a rebuild.

**Live test deferred:** no gateway is running 5.1.29 (kept on older firmware for now). When one is upgraded, exercise the module per SOP (manual `insmod`/`rmmod` on an empty/down port, UTC-bracketed, live trunk watched) and confirm the `dmesg` pr_info sequence (`resolved all symbols` → `port bitmap 0x62 -> 0x42` → `uniphy1 set to SGMII+ 2.5G` → `speed cache ... -> 2500`). Note `clk_rate` is not a mode discriminator on 5.1.19+; verify via `dmesg`, not clock rate.

## Boot Tweak Userland (static presence check against extracted rootfs)

With no live 5.1.29 box, the live "in effect" check is replaced by confirming each tweak's userland surface still exists in the 5.1.29 rootfs. All present, identical to 5.1.26 / 5.1.28:

- **06+07 — MongoDB SSD offload/backup ✓** — `/usr/bin/mongod` (+ `/usr/lib/unifi/bin/mongod`), `ubnt-device-info`, `findmnt`, `mountpoint`, `tar`, `gzip`, `logger`, and both `unifi.service` + `unifi-mongodb.service` units are present.
- **10 — journald volatile ✓** — `/etc/systemd/journald.conf`, the `/etc/syslog-ng/conf.d/*.conf` set (15 files), and the `syslog-ng.service` + `systemd-journald.service` units are present.
- **15 — fan control ✓** — `uhwd.service` + `/usr/sbin/uhwd`, `python3.9`, and the SDB client are present. As on 5.1.26/5.1.28 the SDB client ships as a compiled extension (`ustd/statusdb/sdb_client.cpython-39-aarch64-linux-gnu.so`); the script's `from ustd.statusdb.sdb_client import SDBClient` import path is unchanged, so script 15 is unaffected.
- **19+20 — SFP SGMII+ ✓** — `/sbin/insmod` present.

The `on_boot.d` runner (`udm-boot`) is deployed alongside the scripts by NetworkOptimizer and is not part of stock firmware — its absence from the rootfs is expected, not a compatibility gap.

## Conclusion

UniFi OS 5.1.29 is **statically compatible**. The SGMII+ module is guaranteed by construction: the kernel is unchanged and `qca-ssdk.ko` is **byte-identical to the verified 5.1.26 / 5.1.28 SSDK** (which is code-identical to 5.1.19/5.1.21), so all 10 symbols and both cache offsets are intact. All four deployed Performance Tweaks (06+07+10+15) have their userland dependencies present in the 5.1.29 rootfs. 5.1.29 is a userland/security patch release (see the image-diff notes); it introduces no kernel, driver, or tweak-relevant userland changes. Remaining gap: the live SGMII+ load/unload and the "tweaks in effect" checks, deferred to a later deploy once a gateway is on 5.1.29.
