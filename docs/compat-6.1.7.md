# UniFi OS 6.1.7 Compatibility Verification

**Result: compatible on UCG-Fiber and UCG-Max.** UCG-Fiber: static check of its image, and read-only live checks on two production UCG-Fiber gateways, on 2026-11-28: one without SSD (10 + 15), one with SSD (08 + 09 + 15). UCG-Max: static check of its own image, on 2026-11-28.

- [UCG-Fiber](#ucg-fiber)
- [UCG-Max](#ucg-max)

## UCG-Fiber

| | |
|---|---|
| Build | `UCGF.ipq9574.v6.1.7.2e6c319.261125.1938` |
| `.bin` md5 | `286c9b7d95af92cfddac3a990d359425` (948,530,984 bytes) |
| Rootfs | zstd squashfs at offset `16175306`, 52,393 inodes |
| Kernel | `#5.4.213 SMP PREEMPT Wed Nov 25 19:41:36 CST 2026` (rebuilt, code changed), GCC 14.2.0-19 |
| vermagic | `5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64`, unchanged. No module rebuild. |
| Baseline | 6.0.19 UCG-Fiber image |

| Tweak | Static (UCG-Fiber image) | Live (UCG-Fiber) |
|---|---|---|
| 19 + 20 SGMII+ | ✓ `qca-ssdk.ko` `.text`, `.data`, `.rodata` and symbol table identical to 6.0.19. Both device trees byte-identical. The kernel changes do not reach the structures the module uses (see below) | Not deployed |
| 06 + 07 MongoDB | ✓ `mongod`, `mongodump`, `unifi-mongodb.service`, `/etc/default/unifi` identical to 6.0.19 | N/A (neither gateway runs 06 + 07) |
| 08 + 09 PostgreSQL | ✓ `/etc/default/postgresql/14-apps`, `pg-cluster-setup`, `usr/lib/postgresql/14/`, `usr/share/postgresql-common/`, `/etc/postgresql*` and the units identical to 6.0.19. New `pid-cleanup.conf` drop-in (see below). No new `14-apps` reference | ✓ See below |
| `mongodb-ssd-decommission.sh` | ✓ Its dependencies are covered by the 06 + 07 and 08 + 09 rows | Not run |
| 10 journald | ✓ `journald.conf` identical to 6.0.19. `syslog-ng/` identical except that `vpn_bonding_log.conf` is gone | ✓ See below |
| 15 fan | ✓ `ufcd.service` identical. `ustd` 6.0.11 → 6.1.1: `ufcd`, `uhwd` and `sdb_client.so` `.text` identical to 6.0.19; `statusdb/config.so` and `statusdb/hdl.so` changed | ✓ See below |

### Kernel

This is the first kernel code change since 6.0.17. The decompressed `Image` grows from 13,395,976 to 13,398,024 bytes, and the kallsyms set grows from 36,164 to 36,178 entries. The per-function compare finds:

| Change | Functions |
|---|---|
| Hung task detector enabled | New `hung_task_*`, `watchdog`, `proc_dohung_task_timeout_secs`. `copy_process` +4 bytes, `fork_init` and `cgroup_*` task paths change one word each |
| Workqueue watchdog enabled | New `wq_watchdog_*`. `__queue_work`, `alloc_workqueue`, `workqueue_init` change |
| RTL8372 switch driver | New `rtl8372_link_poll`, `rtl8372_link_poll_work_fn`. `rtl8372_probe` and `rtl8372_remove` grow |
| TCP | `tcp_conn_request`, `tcp_get_cookie_sock`, `__inet_lookup_established`, `__inet6_lookup_established` grow |
| Other | `mmc_attach_mmc`, `mmc_init_card`, `blk_execute_rq`, `notifier_call_chain` |

The hung task fields grow `task_struct` by 16 bytes. That is why 16 in-tree modules (`tun`, `sunrpc`, `nfs`, `fat`, `sctp` and others) changed `.text` at the same size: their `current->` field offsets past the stack canary moved by 16 (for example `tun.ko` `#1600` → `#1616`).

The SGMII+ module is not affected:

- It reads the per-task stack canary at `task_struct` offset `#1104`. The offset is still `#1104` in 6.1.7 (`sctp.ko` and `tun.ko` show the same canary loads in both images).
- It reads no other `task_struct` field. Its other kernel structures are `phy_device`, `phy_driver`, `delayed_work` and `mutex`. No phylib, mutex or timer function changed in the kernel. The workqueue watchdog adds state to worker pools, not to `work_struct` or `delayed_work`. `qca-ssdk.ko`, which owns the `phy_driver` and the delayed work the module patches, compiles to identical code against the 6.1.7 headers.
- The kernel config change is `DETECT_HUNG_TASK` (120 s, `BOOTPARAM_HUNG_TASK_PANIC` not set, so it warns and does not panic), `WQ_WATCHDOG` (warns only) and `DEBUG_NOTIFIERS`. The module's longest sleep is 20 ms, and it registers no notifier. `MODVERSIONS` is still off, so no symbol CRCs apply.
- All 15 kernel symbols the module imports are present in the 6.1.7 kernel, and the 26 symbols it looks up with `kallsyms_lookup_name` are all defined in `qca-ssdk.ko` (`ubnt_send_phy_event` and `ssdk_port_link_notify` included).
- `qca-ssdk.ko` differs only in its build timestamp and Jenkins header paths (`debfactory_stable_6.0` → `debfactory_stable_6.1`), so the 10 symbols and the `0x690`/`0x6d0` cache offsets are intact by construction.

`fdt-1` and `fdt-2` are byte-identical to 6.0.19, and the default configuration is still `ucgfiber-2`.

### Modules

Same 362-module set as 6.0.19. 306 are byte-identical. Of the 56 that changed md5:

- 38 differ only in strings or provenance (build paths and timestamps), including `qca-ssdk.ko` and `qca-nss-dp.ko`. `ipt_NETFLOW.ko` also differs in its `__bug_table` line data.
- 16 in-tree kernel modules changed `.text` at the same size, from the `task_struct` shift above. In the sampled `tun.ko` and `fat.ko`, every changed instruction is a field offset moved by +16.
- `ubnthal.ko` changed code: it drops its private `sha256_*` and `cyg_crc32_accumulate` helpers (−493 bytes of `.text`) and adds the `MT7989` SoC name. `ubnt-device-info model_short` still returns `UCGF` on both live gateways.
- `ui-hdd-pwrctl.ko` changed `.data`.

### Userland

581 packages (6.0.19: 583). `bufferbloat-detector`, `ubntmdnsd` and `unifi-cloud-agent` are gone; `ubnt-igmp-bundles` is new. 73 packages changed version. Those near a tweak:

| Package | 6.0.19 | 6.1.7 |
|---|---|---|
| `ustd` | 6.0.11 (`1fce2ea5`) | 6.1.1 (`722aed0e`) |
| `postgresql-common`, `postgresql-client-common` | 295 | 297 |
| `libpq5` | 18.7 | 19.0 |
| `unifi-core` | 6.0.132 | 6.1.36 |
| `ubnt-tools` | 6.0.23 | 6.1.8 |
| `udapi-server`, `unifi-hal`, `uos-agent` | | rebuilt |

`postgresql-14` (14.25), `python3`, `systemd`, `syslog-ng`, `mongod` and `nginx` (1.30.7) did not change.

`postgresql@14-apps.service.d/pid-cleanup.conf` is new. It runs `/usr/share/postgresql/pid-cleanup 14-apps` as an `ExecStartPre=-`, which removes `/run/postgresql/14-apps.pid` and `<data_directory>/postmaster.pid` before the cluster starts. With 08 the data directory is the bind mount onto the SSD, so this clears a stale PID file on the SSD copy. The live run below starts the cluster through it.

Unit set: 416 units. `ulp-go-restart.service` and `systemd-networkd.service.d/20-lag-bond-wa.conf` are new, and `unifi-cloud-agent.service` is gone. `mcagent`, `udapi-bridge`, `unifi-credential-server` and `uos-agent` units changed. None is a tweak dependency. `/etc/cron.d` is identical.

### Live check

Read-only, on two production UCG-Fiber gateways. Both run the build above, and the deployed scripts are byte-identical to repo HEAD. `udm-boot` finished with status 0 on both. Neither gateway runs SGMII+.

| Tweak | Gateway without SSD (10 + 15) | Gateway with SSD (08 + 09 + 15) |
|---|---|---|
| 08 PostgreSQL offload | N/A | ✓ Booted 6.1.7 at 09:02:35 UTC. At boot the SSD copy was authoritative; the script bound `/data/postgresql/14/apps/data` to the SSD and started cluster `14-apps` at 09:08:14 UTC. `postmaster.pid` on the SSD dates from that start. The running server is 14.25 |
| 09 PostgreSQL backup | N/A | ✓ At boot the script validated the cluster and both backup archives, and installed the helper and cron. The first nightly backup on 6.1.7 runs at 01:30 local time and is not yet observed |
| 10 journald | ✓ `Storage=volatile`, `ForwardToSyslog=no`. 37M in `/run/log/journal`. Script 10 commented out the `log` statements in 10 `conf.d` files at boot; `/var/log/auth.log` was last written 2026-09-26. The 76M in `/var/log/journal` is pre-tweak archives from September | N/A |
| 15 fan | ✓ The upgrade reset SDB `config.fan` to stock (100/68/109/103). Script 15 applied 65/55/85/90 at 17:57:08 UTC with no `ERROR`; `ufcd` restarted at 17:57:09. SDB still holds the tuned values a day later. `fan_ctrl_sm` maps = 4. Actuator inconclusive: the hottest sensor read 50.0 °C, below the 65 °C setpoint, so PWM held the 38 floor | ✓ The upgrade reset SDB `config.fan` to stock (100/68/109/103). Script 15 applied 65/55/85/90 at 09:08:26 UTC with no `ERROR`; `ufcd` restarted the same second, after the write. SDB still holds the tuned values. `fan_ctrl_sm` maps = 4. Actuator: CPU sensors 64.0 to 70.2 °C, above the tuned (65) and below the stock (100) setpoint, drive PWM 53 (2,573 rpm), above the 38 floor |

The `ustd` 6.1.1 changes to `config.so` and `hdl.so` therefore leave script 15's `SDBClient` path working.

No new reference `.ko`: `qca-ssdk.ko` code is identical to `research/qca-ssdk-compare/qca-ssdk-6.0.15.ko`. Working files: `~/fw-617-ucgf/` on the NAS. The kernel `Image` is the gzip at `.bin` offset 747960 (`~/tools-6017/kimg.py`).

## UCG-Max

| | |
|---|---|
| Build | `UCGMAX.ipq5322.v6.1.7.2e6c319.261125.1938` |
| `.bin` md5 | `c70d0157eb0ff54b1b538ef05bf5669d` (834,434,975 bytes) |
| Rootfs | zstd squashfs at offset `15725938` |
| Kernel | `5.4.213-ui-ipq5322` |
| Baseline | UCG-Max 6.0.17 image (no UCG-Max 6.0.19 image on file). UCG-Fiber 6.1.7 image (same release) |

| Tweak | Static (UCG-Max image) |
|---|---|
| 19 + 20 SGMII+ | N/A. The modules are built for `5.4.213-ui-ipq9574` and do not load on the `ipq5322` kernel |
| 06 + 07 MongoDB | ✓ `mongod`, `mongodump`, `unifi-mongodb.service`, `/etc/default/unifi` identical to UCG-Max 6.0.17 and to UCG-Fiber 6.1.7 |
| 08 + 09 PostgreSQL | ✓ `/etc/default/postgresql/14-apps` (14 / apps / `/data/postgresql/14/apps` / 5434), `pg-cluster-setup`, `usr/lib/postgresql/14/`, `usr/share/postgresql-common/`, `/etc/postgresql*`, the units and both `14-apps` drop-ins identical to UCG-Fiber 6.1.7, including the new `pid-cleanup.conf`. Against UCG-Max 6.0.17: `postgresql-14` 14.24 → 14.25 and the new drop-in, as on the UCG-Fiber |
| `mongodb-ssd-decommission.sh` | ✓ Its dependencies are covered by the 06 + 07 and 08 + 09 rows |
| 10 journald | ✓ `journald.conf` identical to UCG-Max 6.0.17. `syslog-ng/` identical to UCG-Fiber 6.1.7; against UCG-Max 6.0.17 only `vpn_bonding_log.conf` is gone |
| 15 fan | ✓ `ufcd`, `uhwd`, `ufcd.service` and all 12 `statusdb` modules byte-identical to UCG-Fiber 6.1.7, where script 15 ran live on two gateways |

Every package common to the UCG-Max and UCG-Fiber 6.1.7 images has the same version; the differences are the SoC and board packages. `python3`, `systemd`, `syslog-ng` and `mongod` did not change from UCG-Max 6.0.17. `ubnt-device-info` still carries `model_short`. The tweak dependencies equal those of the live-checked UCG-Fiber, so the UCG-Max result rests on that live run plus this image compare. No UCG-Max stock fan setpoints are on record.

Working files: `~/fw-617-ucgmax/` and `~/fw-6017-ucgmax/` on the NAS.
