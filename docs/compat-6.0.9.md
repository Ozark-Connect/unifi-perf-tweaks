# UniFi OS 6.0.9 Compatibility Verification

Verified 2026-09-21 (UTC) on a **production UCG-Fiber** running `UCGF.ipq9574.v6.0.9.4781a3e.260914.1420` (built 2026-09-14), up since 2026-09-18 05:02. Two parts:

- **Static:** `qca-ssdk.ko`, the full module set, the package list and the systemd unit set, compared off-box against the 6.0.7 rootfs.
- **Dynamic, read-only:** confirmation that tweaks 06+07+10+15 are in effect after the upgrade. The gateway is production, so nothing was loaded, restarted, re-run or perturbed. All gateway access fell between 16:50:26 and 16:53:11 UTC.

**No firmware image this round.** The `.bin` was not downloaded. The artifacts were pulled from the running gateway instead: `qca-ssdk.ko`, the 28 other modules whose md5 changed (one `tar` stream), `md5sum` of all 362 modules, `dpkg-query -W`, and `systemctl list-unit-files`. This covers the module and package analysis fully. It does not give a `.bin` md5, a rootfs offset, a FIT kernel build string, or a stock (un-tweaked) `journald.conf`/`syslog-ng` baseline.

**Scope:** SGMII+ kernel module (static only, it is not deployed on this gateway) and the Performance Tweaks 06, 07, 10, 15. Adaptive SQM and JVM heap are out of scope.

## Kernel

`uname -a`: `5.4.213-ui-ipq9574 #5.4.213 SMP PREEMPT Mon Sep 14 14:24:33 CST 2026`. The kernel was **rebuilt again** (6.0.7 was `Wed Sep 2 14:15:50 CST 2026`). The module **vermagic is unchanged**: `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`. The repo modules need no rebuild. 362 `.ko`, same file set as 6.0.7 (zero added, zero removed).

## qca-ssdk: one function changed, outside the uniphy path

`qca-ssdk.ko` md5 = `e208a08c499b9af1cbbf0d5c0f2b59df`, 3,446,432 bytes (6.0.7: `3a7adcea…`, 3,445,888). This is the **first real SSDK source change** since the module work began. Every earlier delta was provenance-only or a toolchain recompile.

| Comparison vs 6.0.7 (`3a7adcea…`) | Result |
|---|---|
| Raw `.text` | 982,444 bytes vs 982,340 (**+104**), md5 `3585bdae9397e504e99a4b291d132fa4` |
| `.rodata` / `.data` / `.bss` sizes | 15,739 / 102,904 / 66,936, identical |
| Symbol table (`nm`, unique names) | 9,353 vs 9,353, **zero delta** |
| Compiler | `GCC: (Debian 14.2.0-19) 14.2.0`, unchanged |
| Functions with changed code | **1 of all functions**: `qca_mht_sw_mac_polling_task` |
| Package | `qca-ssdk-ipq9574` `g194f57154225` (6.0.7: `gd424fab85821`) |

Method: per-function disassembly with addresses, branch targets and hex immediates normalized, then compared function by function. The 104-byte growth shifts every later address, so a raw `cmp` reports 29,719 differing `.text` bytes. After normalization exactly one function differs.

`qca_mht_sw_mac_polling_task` grew from 168 to 190 instructions (668 → 756 bytes). The change is:

- Two added `printk` calls, each behind a log-level test (`ldr w0,[x23]; cmp; b.ls`). Source line numbers 305 and 325.
- The third argument of both `mht_port_link_update` calls changed from a variable to the constant `1`.
- Register reallocation (`x23`/`x24`/`x26` swapped) as a consequence.

The call set is otherwise identical (`fal_port_rxmac_status_set`, `fal_port_txmac_status_set`, `hsl_port_phy_status_get`, `qca_ssdk_port_bmp_get`, `ssdk_port_link_notify`, …). This function polls MAC state for ports behind an MHT (QCA8084-class) switch. It does not call or modify anything the SGMII+ module patches.

### Symbols and offsets

All 10 symbols the module needs are present, and resolved live in `/proc/kallsyms`:

```
ffffffc00893e488 t adpt_hppe_uniphy_mode_set
ffffffc008929c08 t _adpt_hppe_port_interface_mode_set
ffffffc0089e6fdc t ssdk_dt_global_set_mac_mode
ffffffc00897b3e0 t qca_ssdk_port_bmp_get
ffffffc00897b3c0 t qca_ssdk_port_bmp_set
ffffffc0089eb910 t ssdk_phy_priv_data_get
ffffffc0089b7e38 t ssdk_port_link_notify
ffffffc00892a7a4 t ubnt_send_phy_event
ffffffc0089eb948 T ssdk_mac_sw_sync_work_stop
ffffffc0089eb9a4 T ssdk_mac_sw_sync_work_start
```

The uniphy/sgmii family count is unchanged from 6.0.7 (zero symbol delta).

**The `0x690`/`0x6d0` speed and duplex cache offsets are unchanged.** `sfp_read_status` sits before the changed function, so even its addresses are the same as 6.0.7:

```
6.0.9    ca478: b9469040   ldr w0, [x2, #1680]   ; 0x690  speed cache
         ca480: b946d040   ldr w0, [x2, #1744]   ; 0x6d0  duplex cache
6.0.7    ca478: b9469040
         ca480: b946d040
```

| Version | md5sum | size | vs reference |
|---|---|---|---|
| 5.1.26 → 5.1.31 (UCGF) | 8033a7fad2fd93eec8173f196d351dc1 | 3,456,424 | GCC 10 build |
| 6.0.5 EA (UXGF) | 151a68f1b2645f45a36aec95084772e6 | 3,445,888 | GCC 14 recompile, ABI intact |
| 6.0.7 (UCGF) | 3a7adcea48e6ff5c8dbf36d22cf353ea | 3,445,888 | `.text` byte-identical to 6.0.5 |
| **6.0.9 (UCGF)** | **e208a08c499b9af1cbbf0d5c0f2b59df** | **3,446,432** | **1 function changed (MHT MAC polling)** |

### The rest of the module set

Of 362 modules, 29 changed md5. Raw `.text` comparison against 6.0.7:

- **26 are `.text`-identical**, including `qca-nss-dp.ko`, `qca-nss-ppe.ko`, `ubnthal.ko` and `ui-hdd-pwrctl.ko`. The differences are provenance and non-code sections.
- **3 changed code:** `qca-ssdk.ko` (above), `ecm.ko` (`.text` 565,180 → 565,796, package `qca-nss-ecm-ipq9574` `g8a2793ccfdd0` → `g3a9b37697829`) and `qca-nss-sfe.ko` (128,440 → 128,452, `qca-nss-sfe-ipq9574` `g8b284440845f` → `g0cdce33d5c77`).

`ecm` and `sfe` are the connection-offload path. No Performance Tweak depends on them. They were not analyzed further.

## Userland

Still Debian 13 trixie. 582 → 609 packages on this gateway; the additions are installed applications (`unifi-protect` 7.3.56, `ai-feature-*`, `ds`, `ms*`, their codec libraries, `postgresql-14-pgvector`), not firmware. Firmware package changes that matter here:

| Package | 6.0.7 | 6.0.9 |
|---|---|---|
| `ustd` | 6.0.6 | **6.0.8** (fan stack, see tweak 15) |
| `unifi-core` | 6.0.104 | 6.0.115 |
| `base-files-deps-*` / `ucgf-ipq9574-base-files` | 6.0.85 | 6.0.94 |
| `kmod-debbox-modules` | 1.16.3 | 1.16.4 |
| `unifi-hal`, `udapi-server`/`libudapi`, `libubnt`/`mcagent` | | new git revisions |
| `qca-ssdk-shell` | `ge690d0d7911c` | `gaa43b5a0fb17` |
| `python3.13` | `deb13u4` | `deb13u5` |
| `gzip` | 1.13-1 | 1.13-1+deb13u1 |
| `libc6` | `deb13u3` | `deb13u4` |

The rest is Debian security maintenance (curl, glib, perl, pcre2, sqlite3, libssh2, samba libs, libevent, tzdata 2026c).

### systemd unit set (new SOP step)

The 6.0.7 round missed `ufcd` because a presence check cannot flag an added component. This round diffed the unit set. Units present on live 6.0.9 and absent from the 6.0.7 rootfs:

- Application units: `unifi-protect*`, `postgresql-cluster-14-protect-*`, `ai-feature-console`, `ai-feature-controller`, `ds`, `ds-monitor`, `ms`, `msp`, `msr`, `mst`, `msx-monitor`, `unifi-user-assets`, `rsync`.
- Ours: `udm-boot`, `sqm-monitor`, `netopt-agent`.
- Runtime/generated: swap units, a session scope, `l2tpd`/`xl2tpd`/`stunnel4`, `sshd-unix-local`.

**No new firmware daemon touches fans, logging, MongoDB or the SFP path.** Caveat: this compares a live unit list to an image file listing, so it is weaker than an image-to-image diff.

## Boot tweaks: dynamic verification (read-only)

`udm-boot.service` active, `ExecMainStatus=0`, entered 05:06:40 local on the 2026-09-18 boot. The four deployed scripts are **byte-identical to repo HEAD** (md5 `120fe20d…`, `825cf5d7…`, `17f91b1f…`, `4c0476b4…`). No `err`-priority journal entries from any tweak tag since boot.

### 06 — MongoDB SSD offload ✓ in effect

`findmnt /data/unifi/data/db` → `/dev/md3[/unifi-db]` ext4. `unifi` and `unifi-mongodb` both active. `mongod --dbpath /data/unifi/data/db --directoryperdb --port 27117` is running on the bind mount. This is the **first live confirmation of 06 on any 6.0.x**, and it closes the 6.0.7 question about the `unifi-mongo-service-helper` pre-start steps: they run cleanly against the SSD-backed directory.

### 07 — MongoDB SSD backup ✓ in effect

`/etc/cron.d/mongodb-ssd-backup` present (01:30 daily, 01:35 Sunday `--emmc`). `/tmp/mongodb-backup.log` shows both paths ran on 6.0.9: Sunday 2026-09-20 01:35 `mongodump` 435M plus the eMMC failover archive (40M), and 2026-09-21 01:30 `mongodump` 434M. `mongodump` and `gzip` (bumped this release) both work.

### 10 — journald volatile ✓ in effect

`journald.conf`: `Storage=volatile`, `ForwardToSyslog=no`, `RuntimeMaxUse=40M`. Live journal is 37M in `/run/log/journal`. 12 `log` statements disabled in `syslog-ng/conf.d`, zero active `log` statements reference a local `/var/log` file destination. syslog-ng persist file redirected to `/run/syslog-ng.persist`.

Observation, not a defect: `/var/log/journal` still holds 81M of archived journals last written 2026-05-08, from before the tweak was deployed. journald does not write there. They are dead weight on a 974M partition at 23% use.

### 15 — fan control ✓ in effect, with actuator evidence

This is the **first field verification of the corrected script 15** (`265f90d`) at boot on a 6.0.x UCG-Fiber.

- The boot log shows the script detected `ufcd.service`, wrote SDB, and restarted `ufcd` (05:05:57 → 05:06:03). `ufcd` `ActiveEnterTimestamp` is 05:05:58, matching the script's restart, so `ufcd` loaded the tuned config.
- SDB `config.fan` reads cpu 65 / hdd 55 / rtl8372 85 / rtl8261 90 / standby 20.
- `fan_ctrl_sm` is mapped in the `ufcd` process (4 mappings).
- **Actuator:** SDB `hardware.cpu` temperature 68.3 °C, which is above the tuned 65 °C setpoint and far below the stock 100 °C. The fan runs at pwm 201-211, 6,826-7,072 rpm. rtl8372 is 65 °C (setpoint 85) and rtl8261 is 80 °C (setpoint 90), so the CPU PID is the one driving. Under stock setpoints every component is below setpoint and the fan would hold the pwm 38 floor, which is the exact 6.0.7 failure signature. The fan is not at the floor, so the tuned setpoints are controlling the loop.

This is observed, not perturbed. It is still effect-level evidence, not an SDB read-back. `ustd` 6.0.6 → 6.0.8 did not change the `SDBClient` `run`/`get` API or the `ufcd` ownership of the loop.

### 19 + 20 — SFP SGMII+ : static only

Not deployed on this gateway (no `19`/`20` script, no module loaded, eth5 up at 10000, eth6 down). Loading the module on a production gateway was out of bounds. The static contract is intact (above). The SFP-negotiation concern raised in the 6.0.7 round is still not live-tested on any UCG-Fiber 6.0.x.

## Conclusion

**6.0.9 is compatible.** Tweaks 06, 07, 10 and 15 are verified in effect on a production UCG-Fiber, with 06+07 live-confirmed for the first time on 6.0.x and the corrected script 15 confirmed at the actuator. The SGMII+ module is statically compatible: vermagic unchanged, all 10 symbols present and resolved live, `0x690`/`0x6d0` encodings identical at identical addresses, and the single changed SSDK function is MHT MAC polling with two added log lines and one constant argument.

### Outstanding

- **SGMII+ live load on a UCG-Fiber 6.0.x** (Lab box): full `dmesg` sequence, 2500Mb/s held across a link flap and re-seat, `rmmod` revert path. Carried over from 6.0.7.
- **6.0.9 `.bin` not archived.** No `.bin` md5, rootfs offset, stock config baseline, or image diff. Download it if an image-level record is wanted.
- `ecm.ko` and `qca-nss-sfe.ko` code changes not analyzed (out of scope for the Performance Tweaks).
- Whether `qca_mht_sw_mac_polling_task` runs at all on the UCG-Fiber was not established. It does not matter for the module contract.
- `force_uniphy2_sgmiiplus.ko` untested on 6.0.x.
- Stale pre-tweak archives in `/var/log/journal` on this gateway (81M). Removal is a change to a production gateway and was not done.

Reference `.ko` stored as `research/qca-ssdk-compare/qca-ssdk-6.0.9.ko`. Pulled artifacts and comparison files in `~/fw-609/` on the RE host.
