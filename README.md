# unifi-perf-tweaks

Performance tuning scripts for UniFi Cloud Gateways (UCG) and UniFi Gateways (UXG). These address real, measured performance issues - eMMC write pressure causing packet loss and overly conservative thermal management. Also includes modules for SFP 2.5G SGMII+ (HSGMII) support on both SFP+ ports (eth5/Port 6 and eth6/Port 7) of the UCG-Fiber and UXG-Fiber, which only have native 1/10 gig support. Several of these tweaks are available as one-click deployments through [Network Optimizer](https://github.com/Ozark-Connect/NetworkOptimizer).

---

## About This Project

These scripts weren't thrown together overnight. They're the result of hundreds of hours of research, profiling, and testing on production UniFi hardware dating back to late 2025.

The performance investigation alone spans months of work: multi-gateway performance comparisons, an OS 5.0 memory and CPU deep dive, a full UniFi Network flow control test suite, and a 3-day packet loss investigation that produced over 1,600 lines of documented findings across multiple research documents. The eMMC write pressure root cause was identified through `fatrace`, `iostat`, and MongoDB slow query profiling, with bulk delete operations correlated to cyclical packet loss windows down to the second.

The JVM work went through 5+ distinct heap configurations, each profiled for hours (some to 23-25 hours) before discovering that Ubiquiti's `-XX:MaxHeapFree` flag, while a real SubstrateVM flag, is an upper-bound cap on retained free space rather than a floor - meaning it can only limit how much free heap the GC keeps around, never prevent shrinking. This invalidates every community tuning guide that raises `MaxHeapFree` to "give the heap more room." After extended testing, JVM heap parameter tweaks showed minimal measurable impact on GC pause behavior - the stock GraalVM Serial GC configuration is already reasonably tuned, and the real wins came from eliminating eMMC write pressure instead. The JVM tuning script is still included for reference but is no longer a recommended deployment. The fan controller reverse engineering involved tearing down the `uhwd` PID control loop, mapping the SDB API, and measuring PWM-to-RPM curves to replace the constant-polling scripts that were themselves contributing to eMMC write pressure.

Every script here has been running on a production gateway serving real users. This is not theoretical.

Several of these tweaks are already available as one-click deployments through [Network Optimizer](https://github.com/Ozark-Connect/NetworkOptimizer), which handles deployment, version tracking, and updates automatically. The scripts here are the upstream source — use them directly if you prefer manual control, or use Network Optimizer if you want a managed experience.

---

## WARNING

**These modifications are at your own risk.**

Everything here has been thoroughly tested and vetted on production hardware - but it's only been tested on a UCG-Fiber. If you're running a different model, there's a real chance something could go wrong due to different paths, mount points, or service behavior. In a worst-case scenario, you may need to factory reset your gateway and restore from backup.

**Before you touch anything:**

1. **Back up your UniFi Console.** Go to Settings > Control Plane > Backups and create a full backup. Download it. Make sure you actually have the file. If you have to factory reset, this is how you get your network back.
2. **Have a plan for recovery.** If things go sideways, you can factory reset (reset button on the device) and restore from your cloud backup or upload your saved backup file through the UI. If you've never done a restore before, this is not the time to learn on the fly.
3. **Have physical access to your gateway.** You need to be able to reach the reset button if a boot script causes issues.

Once you've got your backup sorted:

- These are **unofficial modifications** not endorsed by Ubiquiti
- Ubiquiti **could** consider these warranty-voiding if they wanted to be strict about it
- A misconfigured gateway can take down your entire network
- **Test one script at a time** - don't deploy everything at once
- **Read the documentation** for each script before deploying

If you're not comfortable SSH-ing into your gateway and recovering from a bad boot script, these tweaks are not for you.

---

## Tested Platform

**All scripts have been developed and tested exclusively on a UCG-Fiber.** They should work on other UniFi Cloud Gateway and UDM-Pro based devices, but have **not been verified** on those platforms.

### Verified UniFi OS versions (UCG-Fiber)

The MongoDB SSD scripts (`06-mongodb-ssd-offload.sh` and `07-mongodb-ssd-backup.sh`) have been end-to-end dogfooded on a UCG-Fiber lab unit against:

- **UniFi OS 5.0.16** / UniFi Network 10.2.105 - first-run migration, warm reboot, cold boot (power cycle) all verified clean.
- **UniFi OS 5.1.7 EA** / UniFi Network 10.3.47 - OS upgrade from 5.0.16 verified (the SSD mount path auto-migrated from `/volume1` to `/volume/<uuid>/` and the bind mount re-established on boot without intervention), followed by a Network app upgrade to 10.3.47 with no issues.

In addition, the bind-mount approach (the steady-state runtime behavior) has been in continuous use on a personal UCG-Fiber production gateway for several weeks, covering real traffic, Protect coexistence, nightly backups, and the full eMMC-write-pressure scenarios [documented in docs/](docs/emmc-write-pressure.md).

The JVM heap and non-SSD scripts have lighter verification - see each script's own doc for specifics.

If you're running a different model (UDM-Pro, UDM-SE, UCG-Max, UCG-Ultra, etc.), **you need to verify before deploying:**

- **eMMC device path** - The diagnostic commands in [docs/emmc-write-pressure.md](docs/emmc-write-pressure.md) assume `/dev/mmcblk0`. Run `lsblk` first to confirm your device's eMMC path; no boot script hardcodes it, but the research commands do.
- **SSD mount point** - SSD scripts auto-detect `/volume1` (UniFi OS 5.0.x) and `/volume/<uuid>/` (UniFi OS 5.1.7+ EA), falling back to whatever `/dev/md3` is mounted as. Other models may use a completely different mount path that the auto-detection won't catch - check `lsblk` and `mount` on your device first, and extend `detect_ssd_mount()` in the script if you need to support a different scheme. (UDM models are blocked by a separate model check anyway, so this only matters if you're adapting the scripts for unsupported hardware.)
- **MongoDB data path** - Scripts assume `/data/unifi/data/db`. Confirm with `findmnt` or `ls /data/unifi/data/`.
- **Fan PID categories** - The fan tuning script uses category names from the UCG-Fiber (`cpu`, `hdd`, `rtl8372`, `rtl8261`). Your model will have different hardware and different category names. Always check `config.fan` first - see the [fan tuning docs](docs/fan-control-tuning.md#before-you-apply-check-your-model).
- **Service names** - `uhwd.service`, `unifi.service`, `systemd-journald` should be consistent, but verify.

**When in doubt, read the script, check the paths on your device, and test manually before adding to `/data/on_boot.d/`.**

---

## What Problems Do These Solve?

UniFi Cloud Gateways (particularly models with CPU-attached network ports like the UCG-Fiber's SFP+ interfaces) suffer from intermittent packet loss caused by:

1. **eMMC write pressure** - MongoDB, journald, and syslog all write to eMMC flash by default. The eMMC flash controller's garbage collection stalls I/O and freezes `ubios-udapi-server`, dropping packets for 30+ minute windows.

2. **JVM garbage collection** - The UniFi controller's GraalVM Serial GC produces Full GC pauses (150-350ms) every 30-70 seconds. After extensive profiling, JVM heap parameter tuning showed minimal impact on this behavior - the real fix turned out to be eliminating eMMC write pressure (item 1 above), which was the actual bottleneck causing packet loss during GC windows.

3. **Conservative thermal management** - The fan controller defaults to absurdly high setpoints (CPU at 100C), keeping components hotter than necessary.

See [docs/emmc-write-pressure.md](docs/emmc-write-pressure.md) and [docs/jvm-gc-profiling.md](docs/jvm-gc-profiling.md) for the full research behind these fixes.

## Scripts

| Script | Boot Order | What It Does | Models | Status |
|---|---|---|---|---|
| [`05-jvm-heap-tuning.sh`](scripts/05-jvm-heap-tuning.sh) | 05 | Lock JVM heap to prevent GC thrashing | All UCG | **Low impact** |
| [`06-mongodb-ssd-offload.sh`](scripts/06-mongodb-ssd-offload.sh) | 06 | Move MongoDB from eMMC to NVMe SSD | UCG with NVMe SSD | Stable |
| [`07-mongodb-ssd-backup.sh`](scripts/07-mongodb-ssd-backup.sh) | 07 | Scheduled MongoDB backups (SSD + eMMC failover) | UCG with NVMe SSD | Stable |
| [`10-journald-volatile.sh`](scripts/10-journald-volatile.sh) | 10 | Move system logs to RAM | All UCG | Stable |
| [`15-fan-control-tuning.sh`](scripts/15-fan-control-tuning.sh) | 15 | Lower fan controller temperature setpoints | UCG with uhwd PID fan control | Stable |
| [`19-sfp-sgmiiplus-eth5.sh`](scripts/19-sfp-sgmiiplus-eth5.sh) | 19 | Force 1st SFP+ port (eth5 / Port 6) to 2.5G | UCG-Fiber / UXG-Fiber | **Testing** |
| [`20-sfp-sgmiiplus.sh`](scripts/20-sfp-sgmiiplus.sh) | 20 | Force 2nd SFP+ port (eth6 / Port 7) to 2.5G | UCG-Fiber / UXG-Fiber | **Testing** |

> **JVM heap tuning (`05`):** After extended profiling across 5+ heap configurations, JVM parameter tweaks showed minimal measurable impact on GC pause behavior. The stock GraalVM Serial GC configuration is already reasonably tuned. The real wins came from eliminating eMMC write pressure (scripts `06` and `10`). The script is included for reference but is not a recommended deployment.

### Boot Order

Scripts run alphabetically via `/data/on_boot.d/`. The numbering gives you a sensible default order. You can renumber to fit your existing boot scripts, but **respect the dependency chain:**

- **`05` must come before `06`** - JVM heap tuning edits `/etc/default/unifi`, and `06` is what triggers the unifi restart that picks up the new config. If `06` runs first, unifi restarts with stock heap and the JVM fix is queued until the next reboot (two-reboot convergence instead of one).
- **`07` must come after `06`** - the backup script depends on the SSD offload being set up.
- `05`/`06`/`07` run first so the unifi restart happens up front. Everything after (`10`, `15`, and any third-party scripts you add) runs against a stable, bind-mounted, already-restarted environment.
- `10`, `15`, `19`, and `20` are independent and non-disruptive (no unifi restart). Order between them doesn't matter.
- **If you add your own boot scripts** that touch mongo or unifi (mongodump, API calls, etc.), number them >= `10` so they run after `06` has finished the bind mount and service restart.

### Model Compatibility

| Model | journald | JVM heap | Fan tuning | MongoDB SSD | SFP+ 2.5G | Tested? |
|---|---|---|---|---|---|---|
| **UCG-Fiber** | Yes | Yes | Yes | Yes | Yes | **Yes** |
| **UXG-Fiber** | Yes | Yes | Yes | No SSD | Yes | **Yes** |
| **UCG-Max** | Likely | Likely | Check `config.fan` | Allowed, unverified | No | No |
| **UCG-Ultra** | Likely | Likely | Check `config.fan` | No SSD | No | No |
| **UCG-Lite** | Likely | Likely | Check `config.fan` | No SSD | No | No |
| **UCG-Industrial** | Likely | Likely | Check `config.fan` | **Blocked by model check** (no SSD, microSD reserved for NVR) | No | No |
| **UDM-Pro** | Likely | Likely | Check `config.fan` | **Blocked by model check** (no internal SSD) | No | No |
| **UDM-SE** | Likely | Likely | Check `config.fan` | **Blocked by model check** (already on SSD) | No | No |
| **UDM-Pro Max** | Likely | Likely | Check `config.fan` | **Blocked by model check** (already on SSD) | No | No |

"Likely" means the underlying mechanism (systemd, JVM config) should be the same, but paths and device names may differ. **Verify on your device before deploying.**

"Check `config.fan`" means: run the diagnostic command in the [fan tuning docs](docs/fan-control-tuning.md#before-you-apply-check-your-model) to see what PID categories your model has. The script safely skips categories that don't exist.

"Allowed, unverified" means: the SSD scripts will run on UCG-Max (same NVMe SSD layout as UCG-Fiber, same `unifi-mongodb.service` stack), but no one has soak-tested them on that hardware. If you're running UCG-Max, **make a full controller backup from the UI first**, watch the first reboot carefully, and open an issue if anything misbehaves.

"Blocked by model check" means: the SSD scripts (`06-mongodb-ssd-offload.sh` and `07-mongodb-ssd-backup.sh`) read the device model from `ubnt-device-info` / `/proc/ubnthal/system.info` at the top and refuse to run on anything other than UCG-Fiber or UCG-Max. On UDM models the reasoning depends on the specific hardware:

- **UDM-SE: already on SSD, confirmed.** On a UDM-SE, `/dev/sda5` (the 119 GB internal SATA SSD) is mounted at `/ssd1`, and MongoDB data lives at `/ssd1/.data/unifi/data/db`. Ubiquiti already put the database on the fast storage - there's nothing to offload. Running these scripts is pointless.
- **UDM-Pro Max: same arrangement, inferred.** UDM-Pro Max ships with an internal SSD and almost certainly uses the same layout as UDM-SE, though we haven't first-hand verified it.
- **UDM-Pro: no internal SSD.** UDM-Pro has no built-in SSD - MongoDB runs on eMMC by default (same class of problem as UCG-Fiber). Users typically add their own drive to the 3.5" bay. In principle this fix *could* apply, but the storage layout on a UDM-Pro with a user-added drive is different enough that the scripts would need real adaptation and testing on that hardware. The model check refuses it for now.
- **UCG-Industrial: no SSD or M.2 slot.** UCG-Industrial ships with a pre-installed 128 GB microSD reserved for NVR, plus a microSD expansion slot - no SATA or NVMe. microSD is slower than eMMC for sustained random writes and is committed to Protect anyway, so there's nothing usable to offload MongoDB to. This fix doesn't apply.
- **The detection logic wouldn't help here anyway.** UDM-SE uses `/ssd1`, not `/volume1` or `/volume/<uuid>/`, and there's no `/dev/md3` for the findmnt fallback. So `detect_ssd_mount()` would return failure on its own - but the explicit model check surfaces the refusal clearly in logs instead of a cryptic "no SSD mount found".

If you're on a UDM-SE or UDM-Pro Max and experiencing eMMC-style symptoms like those in [docs/emmc-write-pressure.md](docs/emmc-write-pressure.md), this isn't the right fix - your MongoDB is already on SSD, so whatever you're seeing has a different cause. If you're on a UDM-Pro and want to adapt these scripts for a user-added drive, you'll need to edit the model check and extend `detect_ssd_mount()` - manually, and with real testing, not a blind deploy.

## Prerequisites

See [docs/prerequisites.md](docs/prerequisites.md) for detailed setup instructions.

**Short version:**
1. SSH access to your gateway (`ssh root@<gateway-ip>`)
2. **[udm-boot](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) installed** - this is what makes `/data/on_boot.d/` scripts run on boot. It doesn't ship with the gateway; you have to install it first. See [docs/prerequisites.md](docs/prerequisites.md) for instructions.

## Quick Start

**Make sure [udm-boot](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) is installed first.** Without it, your scripts in `/data/on_boot.d/` won't run on boot. See [docs/prerequisites.md](docs/prerequisites.md) for install steps.

```bash
# 1. Clone this repo
git clone git@github.com:Ozark-Connect/unifi-perf-tweaks.git
cd unifi-perf-tweaks

# 2. Copy the script(s) you want to your gateway
scp scripts/10-journald-volatile.sh root@<gateway-ip>:/data/on_boot.d/

# 3. Make executable
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/10-journald-volatile.sh"

# 4. Test run (doesn't require reboot)
ssh root@<gateway-ip> /data/on_boot.d/10-journald-volatile.sh

# 5. Verify
ssh root@<gateway-ip> journalctl --header | grep "File path"
```

**Deploy one script at a time.** Verify it works before adding the next one.

## Updating

There's no `git` on the UniFi console, so updates have to be pushed manually from your local clone of this repo. The flow mirrors the Quick Start.

On your local machine, pull and review:

```bash
cd unifi-perf-tweaks
git pull
git log --oneline HEAD@{1}..HEAD   # see what changed
```

Then push whichever scripts were updated (overwriting the existing file is fine):

```bash
scp scripts/06-mongodb-ssd-offload.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/06-mongodb-ssd-offload.sh"
```

When the new version actually takes effect depends on what kind of script it is:

- **Config-file scripts** (`05-jvm-heap-tuning`, `10-journald-volatile`, `15-fan-control-tuning`): the new logic runs on next boot. To apply it right away, re-run the script manually (`ssh root@<gateway-ip> /data/on_boot.d/<script>.sh`). For `05`, you'll also need to `systemctl restart unifi` afterward for the controller to pick up new JVM flags.
- **SSD offload** (`06`): replacing the script file does not change the live bind mount. The new boot-time logic runs on next boot. You can also re-run it manually, which is idempotent - if the bind mount is already set up, the script exits early without doing anything.
- **Backup** (`07`): re-run manually to reinstall the cron and the `/data/unifi-db-ssd/backup.sh` helper with the new version. Changes to the backup schedule take effect immediately.

If you've modified a script locally (for example, changed the heap sizes at the top of `05-jvm-heap-tuning.sh`), `git pull` may throw a merge conflict, and overwriting on the gateway with `scp` will lose your edits. Keep a note of any local changes, or track them on a local branch.

There's no version fingerprint baked into the scripts today. If you need to know what version is running on a given gateway, compare the file on the gateway against your local clone, or trust that what you last `scp`'d is what's there.

## Documentation

Each script has detailed documentation in [`docs/`](docs/):

- [journald-volatile.md](docs/journald-volatile.md) - trade-offs, verification, reverting
- [jvm-heap-tuning.md](docs/jvm-heap-tuning.md) - GC profiling data, why MaxHeapFree does nothing
- [fan-control-tuning.md](docs/fan-control-tuning.md) - PID controller explained, per-model setup
- [mongodb-ssd-offload.md](docs/mongodb-ssd-offload.md) - migration, firmware upgrade safety
- [mongodb-ssd-backup.md](docs/mongodb-ssd-backup.md) - backup schedule, failover strategy
- [sfp-sgmiiplus.md](docs/sfp-sgmiiplus.md) - SFP+ 2.5G kernel module, deployment, caveats

### Research

- [emmc-write-pressure.md](docs/emmc-write-pressure.md) - Why eMMC writes cause packet loss on UCGs
- [jvm-gc-profiling.md](docs/jvm-gc-profiling.md) - GraalVM Serial GC profiling results and analysis
- [prerequisites.md](docs/prerequisites.md) - Gateway setup, udm-boot, firmware compatibility

### Diagnostics

Read-only snapshot of memory, tmpfs, journald volatile cap, OOM events, and UniFi JVM heap:

```bash
ssh root@<gateway-ip> 'sh -s' < scripts/diagnostics/memory-report.sh
```

Useful for confirming the volatile journal is capped, the JVM is within `-Xmx`, and nothing is leaking before/after deploying the tweaks.

SFP+ port status check - reads the uniphy SerDes registers and clock rates for both SFP+ ports:

```bash
ssh root@<gateway-ip> 'sh -s' < scripts/diagnostics/sfp-link-check.sh
```

Reports the actual physical-layer speed by reading uniphy SerDes registers directly. Useful for confirming the SGMII+ module is working. With module v4+, `ethtool` and the UniFi UI also report 2500 Mbps correctly.

## Reverting

Every script is designed to be safely reversible:

- **journald & JVM heap:** The config files (`/etc/systemd/journald.conf`, `/etc/default/unifi`) are on the overlay filesystem but are **preserved across reboots** - removing the boot script alone does not revert them. You must manually restore stock values (see each script's docs for the sed commands) or wait for a UniFi OS upgrade, which resets the overlay. Either way, remove the boot script first so it doesn't re-apply on the next boot.
- **Fan tuning:** `systemctl restart uhwd` immediately resets `config.fan` to defaults (the fan config lives in SDB runtime state, not a file). Remove the boot script to make it permanent.
- **MongoDB SSD:** See [docs/recovery.md](docs/recovery.md) for the full rollback guide. It covers four scenarios, because the right path depends on *why* you're rolling back: **Path D** (first-run install rollback - use when you just deployed `06` and something went wrong, or you changed your mind within minutes), **Path A** (live-migrate back to eMMC with current data - use when the SSD is healthy and you want off the offload after running it for a while, ~95% of rollbacks), **Path B** (mongorestore from the latest `07-mongodb-ssd-backup.sh` dump - use when the SSD or its data is broken), or **Path C** (nuclear fallback on the pre-deploy eMMC snapshot - stale, only use if Paths A and B both fail). In every path, stop `unifi-mongodb.service` *before* `umount` - the unmount fails with EBUSY while mongod has files open on the bind mount, and a plain `systemctl stop unifi` does not stop mongod (it's owned by a separate unit).

## Contributing

1. **Start with one script** - don't deploy everything at once
2. **Monitor for 24+ hours** before adding another script
3. **Report back** with your gateway model, UniFi OS version, UniFi Network version, and results
4. If something breaks, document what happened and how you recovered

## Acknowledgments

- [@mark0263](https://github.com/mark0263) - confirmed the UDM-SE storage layout (`/dev/sda5` → `/ssd1`, MongoDB at `/ssd1/.data/unifi/data/db`), which is the basis for the UDM-SE entry in the model compatibility table, and tested the scripts across multiple UniFi OS versions on a UCG-Fiber lab unit, surfacing the boot-time `activating`-state bug in `stop_mongod_and_unifi()` among others.
- [@digaus](https://github.com/digaus) - hands-on testing of the Zyxel PMG3000-D20B, confirming firmware reverse-engineering findings on the module, and verifying that the firmware upgrade to the V2.50 lineage fixed the remaining SFP PHY issues.

## License

MIT License. See [LICENSE](LICENSE).
