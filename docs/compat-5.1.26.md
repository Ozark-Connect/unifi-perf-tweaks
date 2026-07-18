# UniFi OS 5.1.26 EA Compatibility Verification

Verified 2026-07-18 (UTC). Firmware `UCGF-5.1.26` (build string `UCGF.ipq9574.v5.1.26.6de03ba.260716.1422`) was expanded and analyzed statically on the RE host (`root@nas`); nothing was run on a gateway. The release `.bin` (`3c66-UCGF-5.1.26-335986d7-...bin`, md5 `e66f972e1fec0e86130fdd2d3da9d70e`) carries a zstd squashfs rootfs (`PARTrootfs`, 940,483,025 bytes) carved from offset `0xC56636`.

**Scope:** SGMII+ kernel module (static) and the userland surface the deployed Performance Tweaks depend on (MongoDB SSD offload/backup 06/07, journald volatile 10, fan control 15). This is a **static-only** round — no gateway is running 5.1.26 yet (the field gateways are on older firmware), so the live SGMII+ load/unload is deferred to a NetworkOptimizer field deploy, same posture as the 5.1.19 round. Adaptive SQM and JVM heap are out of scope (not Performance Tweaks).

## Kernel & qca-ssdk

- `uname -r` = `5.4.213-ui-ipq9574` — **unchanged** from 5.0.10 / 5.1.12 / 5.1.15 / 5.1.19 / 5.1.21. Confirmed both in the extracted rootfs (`lib/modules/5.4.213-ui-ipq9574/`) and live by the user on a 5.1.26 box (`ucg-fiber-pf-1`). Module vermagic matches; no rebuild needed.
- `qca-ssdk.ko` (3,456,424 bytes, unchanged size) md5 = `8033a7fad2fd93eec8173f196d351dc1` — **not byte-identical** to 5.1.19/5.1.21, but **code-identical**. This is the 5.1.19-style result (different md5 from non-code ELF metadata only), not the 5.1.21 byte-identical case.

| Version | md5sum | vs reference |
|---|---|---|
| 5.1.15 | 8b6799b7c4ada78c389b8b8381ad6b4a | `.text`-identical to 5.1.12 |
| 5.1.19 | dd7911587eae837dcf0ffef30fa5be62 | `.text`-identical to 5.1.15 |
| 5.1.21 | dd7911587eae837dcf0ffef30fa5be62 | byte-identical to 5.1.19 |
| 5.1.26 | 8033a7fad2fd93eec8173f196d351dc1 | **`.text`-identical to 5.1.19/5.1.21** |

### Code-identity evidence (5.1.26 vs 5.1.19 reference)

- **`.text` raw bytes byte-identical** — `objdump -s -j .text` md5 `d1d59e098428bbde63e9438c644552ec` on both.
- **Full `.text` disassembly diff = zero instruction changes.**
- **Section layout identical** (only the embedded filename in the objdump header differs).
- **`.modinfo`/vermagic byte-identical** and **`.comment` byte-identical** (same compiler, GCC Debian 10).
- **All 10 required SGMII+ symbols present at byte-identical addresses and linkage** (5.1.19 → 5.1.26):

  | Symbol | Addr | Type |
  |---|---|---|
  | `adpt_hppe_uniphy_mode_set` | `0x38200` | T |
  | `_adpt_hppe_port_interface_mode_set` | `0x234a8` | t |
  | `ssdk_dt_global_set_mac_mode` | `0xe107c` | T |
  | `qca_ssdk_port_bmp_get` | `0x75458` | T |
  | `qca_ssdk_port_bmp_set` | `0x75438` | T |
  | `ssdk_phy_priv_data_get` | `0xe5978` | T |
  | `ssdk_port_link_notify` | `0xb1ec4` | T |
  | `ubnt_send_phy_event` | `0x24068` | t |
  | `ssdk_mac_sw_sync_work_stop` | `0xe59b0` | T |
  | `ssdk_mac_sw_sync_work_start` | `0xe5a0c` | T |

- Speed cache offset `0x690` / duplex cache offset `0x6d0` — **1 reference each** in `.text`, same as 5.1.15/5.1.19. The offsets the module depends on are intact by construction.

### The 41 differing bytes are all build provenance (0 in code)

`cmp -l` reports exactly 41 differing bytes, and **none fall inside any code section** (`.text`/`.text.unlikely`/`.init.text`/`.exit.text` span file offset `0x80`–`0xf34e0`):

- **20 bytes** in `.note.gnu.build-id` — the per-build hash.
- **~7 bytes** — an embedded build-timestamp string in `.rodata.str1.1`: `2026-07-15-18:44:45` (5.1.26) vs `2026-06-05-11:00:36` (5.1.19).
- **~14 bytes** — a Jenkins job-id inside a `__FILE__` path string in `.rodata.str`: `.../debfactory_stable_5.1/220-35kc/build/...` (5.1.26) vs `.../181-40r8/build/...` (5.1.19).

None of these are referenced by the module's logic or affect any symbol/offset it resolves.

## SGMII+ Module Load Readiness

Both repo modules — `force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.ko` and `force-uniphy2-sgmiiplus/force_uniphy2_sgmiiplus.ko` — carry vermagic `5.4.213-ui-ipq9574`, matching the firmware kernel. Combined with the code-identical qca-ssdk (all 10 kallsyms targets and both cache offsets intact), the modules will `insmod` and resolve on 5.1.26 without a rebuild.

**Live test deferred:** no gateway is running 5.1.26 yet. When one is upgraded, exercise the module per SOP (manual `insmod`/`rmmod` on an empty/down port, UTC-bracketed, live trunk watched) and confirm the `dmesg` pr_info sequence (`resolved all symbols` → `port bitmap 0x62 -> 0x42` → `uniphy1 set to SGMII+ 2.5G` → `speed cache ... -> 2500`). Note `clk_rate` is not a mode discriminator on 5.1.19+; verify via `dmesg`, not clock rate.

## Boot Tweak Userland (static presence check against extracted rootfs)

With no live 5.1.26 box, the live "in effect" check from the 5.1.21 round is replaced by confirming each tweak's userland surface still exists in the 5.1.26 rootfs. All present:

- **06 / 07 — MongoDB SSD offload/backup ✓** — `/usr/bin/mongod` (+ `/usr/lib/unifi/bin/mongod`), `ubnt-device-info`, `findmnt`, `mountpoint`, `tar`, `gzip`, `logger`, and both `unifi.service` + `unifi-mongodb.service` units are present.
- **10 — journald volatile ✓** — `/etc/systemd/journald.conf`, `/etc/syslog-ng/conf.d/*.conf`, and the `syslog-ng.service` + `systemd-journald.service` units are present.
- **15 — fan control ✓** — `uhwd.service` + `/usr/sbin/uhwd`, `python3.9`, and the SDB client are present. Note: on 5.1.26 the SDB client ships as a **compiled extension** (`ustd/statusdb/sdb_client.cpython-39-aarch64-linux-gnu.so`) rather than a `.py`; the script's `from ustd.statusdb.sdb_client import SDBClient` import path is unchanged, so script 15 is unaffected.
- **19 / 20 — SFP SGMII+ ✓** — `/sbin/insmod` present.

The `on_boot.d` runner (`udm-boot`) is deployed alongside the scripts by NetworkOptimizer and is not part of stock firmware — its absence from the rootfs is expected, not a compatibility gap.

## Conclusion

UniFi OS 5.1.26 EA is **statically compatible**. The SGMII+ module is guaranteed by construction: the kernel is unchanged and `qca-ssdk.ko` is code-identical to the verified 5.1.19/5.1.21 SSDK (`.text` byte-identical, zero disassembly diff, all 10 symbols and both cache offsets intact) — the differing md5 traces entirely to build-id, an embedded build timestamp, and a Jenkins job-id path string, none in code. All four deployed Performance Tweaks (06/07/10/15) have their userland dependencies present in the 5.1.26 rootfs. Remaining gap vs the 5.1.21 round: the live SGMII+ load/unload and the "tweaks in effect" checks, both deferred to a NetworkOptimizer field deploy once a gateway is on 5.1.26.
