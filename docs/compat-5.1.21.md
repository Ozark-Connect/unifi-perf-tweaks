# UniFi OS 5.1.21 EA Compatibility Verification

Verified 2026-06-26 on a test UCG-Fiber running UniFi OS 5.1.21 EA. All timestamps UTC. The gateway booted `2026-06-26 15:41:15Z`; udm-boot finished `status=0/SUCCESS`.

**Scope:** SGMII+ kernel module (static + live) and the Network Optimizer Performance Tweaks deployed on this box: MongoDB SSD offload/backup (06/07), journald volatile (10), fan control (15). Adaptive SQM and JVM heap are out of scope (not Performance Tweaks).

## Kernel & qca-ssdk

- `uname -r` = `5.4.213-ui-ipq9574` — unchanged from 5.0.10 / 5.1.12 / 5.1.15 / 5.1.19. Module vermagic matches; no rebuild needed.
- `qca-ssdk.ko` md5 = `dd7911587eae837dcf0ffef30fa5be62` — **byte-identical to 5.1.19** (`cmp` clean against the pulled 5.1.19 reference). 5.1.19 was previously verified `.text`-identical to 5.1.12/5.1.15, so the SSDK is unchanged across all of 5.1.12 → 5.1.21. Every symbol and the `0x690`/`0x6d0` cache offsets the module depends on are therefore intact by construction.

| Version | md5sum | vs reference |
|---|---|---|
| 5.1.15 | 8b6799b7c4ada78c389b8b8381ad6b4a | `.text`-identical to 5.1.12 |
| 5.1.19 | dd7911587eae837dcf0ffef30fa5be62 | `.text`-identical to 5.1.15 |
| 5.1.21 | dd7911587eae837dcf0ffef30fa5be62 | **byte-identical to 5.1.19** |

## SGMII+ Module Live Test

Manual `insmod`/`rmmod` on the empty/down eth6 (the live eth5 10G DAC trunk was watched throughout). UTC-bracketed per SOP.

- **Loaded `2026-06-26 15:53:41Z`** (`insmod rc=0`):
  ```
  force_sgmiiplus: resolved all symbols
  force_sgmiiplus: port bitmap 0x62 -> 0x42 (port 5 excluded)
  force_sgmiiplus: uniphy1 set to SGMII+ 2.5G
  force_sgmiiplus: loop restarted (port 5 excluded)
  force_sgmiiplus: speed cache 65535 -> 2500
  force_sgmiiplus: speed reporting updated
  ```
- **Unloaded `2026-06-26 15:54:04Z`** (`rmmod rc=0`, ~23 s loaded):
  ```
  force_sgmiiplus: speed cache restored to 65535
  force_sgmiiplus: reverted, loop restarted with full bitmap 0x62
  ```
- **eth5 stayed up (carrier=1, 10000) through load and unload.** Port-5 bitmap exclusion works as designed.
- Residual (no-reboot): same as 5.1.19 — module exit leaves uniphy1 in SGMII 1G; harmless on the empty eth6. `clk_rate` is not a mode discriminator on this firmware (all uniphys idle at 312.5M); verify via `dmesg -T`.

## Boot Tweak Health (read-only, this boot)

udm-boot ran 06 → 07 → 10 → 15 in order and exited `status=0`. No tweak-attributable errors in the journal. (The `mcad ... inform Unreachable` err-priority lines are the controller waiting for the Network app during boot — normal startup, unrelated.)

### 06 — MongoDB SSD offload ✓
- `Bind mount active: /data/unifi/data/db -> /volume/7dbc…/unifi-db (SSD)`, then `UniFi controller started on SSD-backed MongoDB`.
- Live: `/dev/md3` (NVMe) mounted at `/data/unifi/data/db`, confirmed a mountpoint.
- Re-confirmed after a subsequent **UniFi Network app upgrade to 10.5.54** (`unifi-native 10.5.54-35146-1`): bind mount intact (`findmnt` → `/dev/md3[/unifi-db]`, md3 = raid1 on `nvme0n1p5`), mongod `dbpath=/data/unifi/data/db` (pid live), and WiredTiger actively checkpointing to the SSD. The app upgrade did not disturb the bind mount.

### 07 — MongoDB SSD backup ✓
- Backup script + `/etc/cron.d/mongodb-ssd-backup` installed; existing backup preserved (idempotent skip).

### 10 — journald volatile ✓
- `Storage=volatile`; journal on tmpfs `/run/log/journal/…`; syslog-ng local eMMC routes disabled, remote + tmpfs destinations intact.

### 15 — fan control ✓
- The 5.1.21 upgrade reset the SDB fan config to stock (`cpu:100 hdd:68 rtl8372:109 rtl8261:103`); the script **re-applied** the tuned setpoints this boot (`AFTER: cpu:65 hdd:55 rtl8372:85 rtl8261:90`, standby 20) and restarted uhwd. Live SDB read confirms the tuned values are in effect.

## Conclusion

UniFi OS 5.1.21 EA is **fully compatible**. The SGMII+ module is statically guaranteed (qca-ssdk byte-identical to verified 5.1.19) and passed a live load/unload test with the live trunk undisturbed. All four deployed Performance Tweaks (06/07/10/15) are confirmed in effect, with the fan tweak correctly re-tuning after the upgrade reset the SDB to stock.
