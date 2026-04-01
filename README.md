# unifi-perf-tweaks

Performance tuning scripts for UniFi Cloud Gateways (UCG). These address real, measured performance issues - eMMC write pressure causing packet loss, JVM garbage collection stalls, and overly conservative thermal management.

> **This is a private beta.** These scripts have been extensively tested on a production UCG-Fiber, but every network is different. You're here to test and report back.

---

## About This Project

These scripts weren't thrown together overnight. They're the result of hundreds of hours of research, profiling, and testing on production UniFi hardware dating back to late 2025.

The performance investigation alone spans months of work: multi-gateway performance comparisons, an OS 5.0 memory and CPU deep dive, a full UniFi Network flow control test suite, and a 3-day packet loss investigation that produced over 1,600 lines of documented findings across multiple research documents. The eMMC write pressure root cause was identified through `fatrace`, `iostat`, and MongoDB slow query profiling, with bulk delete operations correlated to cyclical packet loss windows down to the second.

The JVM work went through 5+ distinct heap configurations, each profiled for hours (some to 23-25 hours) before discovering that Ubiquiti's `-XX:MaxHeapFree` flag is an Android ART artifact that GraalVM silently ignores - invalidating every community tuning guide on the topic. JVM heap tuning and long-term soak testing is still ongoing as of this writing. The fan controller reverse engineering involved tearing down the `uhwd` PID control loop, mapping the SDB API, and measuring PWM-to-RPM curves to replace the constant-polling scripts that were themselves contributing to eMMC write pressure.

Every script here has been running on a production gateway serving real users. This is not theoretical.

Once we've collected enough testing data across different models and configurations, these performance enhancements will be integrated into [Network Optimizer](https://github.com/Ozark-Connect/NetworkOptimizer) as automated, one-click deployments.

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

**All scripts have been developed and tested exclusively on a UCG-Fiber** running UniFi OS 5.0.10 / UniFi Network 10.2.10x. They should work on other UniFi Cloud Gateway and UDM-Pro based devices, but have **not been verified** on those platforms.

If you're running a different model (UDM-Pro, UDM-SE, UCG-Max, UCG-Ultra, etc.), **you need to verify before deploying:**

- **eMMC device path** - Scripts reference `/dev/mmcblk0`. Your device may use a different block device.
- **SSD mount point** - SSD scripts assume `/volume1`. UDM-Pro mounts the HDD/SSD differently (often `/mnt/data` or `/data_ext`). Check `lsblk` and `mount` on your device.
- **MongoDB data path** - Scripts assume `/data/unifi/data/db`. Confirm with `findmnt` or `ls /data/unifi/data/`.
- **Fan PID categories** - The fan tuning script uses category names from the UCG-Fiber (`cpu`, `hdd`, `rtl8372`, `rtl8261`). Your model will have different hardware and different category names. Always check `config.fan` first - see the [fan tuning docs](docs/fan-control-tuning.md#before-you-apply-check-your-model).
- **Service names** - `uhwd.service`, `unifi.service`, `systemd-journald` should be consistent, but verify.

**When in doubt, read the script, check the paths on your device, and test manually before adding to `/data/on_boot.d/`.**

---

## What Problems Do These Solve?

UniFi Cloud Gateways (particularly models with CPU-attached network ports like the UCG-Fiber's SFP+ interfaces) suffer from intermittent packet loss caused by:

1. **eMMC write pressure** - MongoDB, journald, and syslog all write to eMMC flash by default. The eMMC flash controller's garbage collection stalls I/O and freezes `ubios-udapi-server`, dropping packets for 30+ minute windows.

2. **JVM garbage collection** - The UniFi controller's stock heap configuration causes Full GC pauses (150-350ms) every 30-70 seconds. Each pause can drop packets on CPU-attached ports.

3. **Conservative thermal management** - The fan controller defaults to absurdly high setpoints (CPU at 100C), keeping components hotter than necessary.

See [docs/emmc-write-pressure.md](docs/emmc-write-pressure.md) and [docs/jvm-gc-profiling.md](docs/jvm-gc-profiling.md) for the full research behind these fixes.

## Scripts

| Script | Boot Order | What It Does | Models |
|---|---|---|---|
| [`10-journald-volatile.sh`](scripts/10-journald-volatile.sh) | 10 | Move system logs to RAM | All UCG |
| [`11-jvm-heap-tuning.sh`](scripts/11-jvm-heap-tuning.sh) | 11 | Fix JVM heap to prevent GC thrashing | All UCG |
| [`15-fan-control-tuning.sh`](scripts/15-fan-control-tuning.sh) | 15 | Lower fan controller temperature setpoints | UCG with uhwd PID fan control |
| [`20-mongodb-ssd-offload.sh`](scripts/20-mongodb-ssd-offload.sh) | 20 | Move MongoDB from eMMC to NVMe SSD | UCG with NVMe SSD |
| [`21-mongodb-ssd-backup.sh`](scripts/21-mongodb-ssd-backup.sh) | 21 | Scheduled MongoDB backups (SSD + eMMC failover) | UCG with NVMe SSD |

### Boot Order

Scripts run alphabetically via `/data/on_boot.d/`. The numbering gives you a sensible default order. You can renumber to fit your existing boot scripts, but **respect the dependency chain:**

- `10` and `11` have no dependencies - run them early
- `15` needs `uhwd.service` running (it waits internally, so order doesn't matter much)
- **`21` must come after `20`** - the backup script depends on the SSD offload being set up
- `20` benefits from running later (gives `/volume1` time to mount)

### Model Compatibility

| Model | journald | JVM heap | Fan tuning | MongoDB SSD | Tested? |
|---|---|---|---|---|---|
| **UCG-Fiber** | Yes | Yes | Yes | Yes | **Yes** |
| **UCG-Max** | Likely | Likely | Check `config.fan` | Check SSD path | No |
| **UCG-Ultra** | Likely | Likely | Check `config.fan` | No SSD | No |
| **UCG-Lite** | Likely | Likely | Check `config.fan` | No SSD | No |
| **UDM-Pro** | Likely | Likely | Check `config.fan` | Check SSD path | No |
| **UDM-SE** | Likely | Likely | Check `config.fan` | Check SSD path | No |
| **UDM-Pro Max** | Likely | Likely | Check `config.fan` | Check SSD path | No |

"Likely" means the underlying mechanism (systemd, JVM config) should be the same, but paths and device names may differ. **Verify on your device before deploying.**

"Check `config.fan`" means: run the diagnostic command in the [fan tuning docs](docs/fan-control-tuning.md#before-you-apply-check-your-model) to see what PID categories your model has. The script safely skips categories that don't exist.

"Check SSD path" means: your model may mount the SSD at a different path than `/volume1`. Run `lsblk` and `mount` to find the correct mount point, then update `SSD_DB_DIR` at the top of the script.

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

## Documentation

Each script has detailed documentation in [`docs/`](docs/):

- [journald-volatile.md](docs/journald-volatile.md) - trade-offs, verification, reverting
- [jvm-heap-tuning.md](docs/jvm-heap-tuning.md) - GC profiling data, why MaxHeapFree does nothing
- [fan-control-tuning.md](docs/fan-control-tuning.md) - PID controller explained, per-model setup
- [mongodb-ssd-offload.md](docs/mongodb-ssd-offload.md) - migration, firmware upgrade safety
- [mongodb-ssd-backup.md](docs/mongodb-ssd-backup.md) - backup schedule, failover strategy

### Research

- [emmc-write-pressure.md](docs/emmc-write-pressure.md) - Why eMMC writes cause packet loss on UCGs
- [jvm-gc-profiling.md](docs/jvm-gc-profiling.md) - GraalVM Serial GC profiling results and analysis
- [prerequisites.md](docs/prerequisites.md) - Gateway setup, udm-boot, firmware compatibility

## Reverting

Every script is designed to be safely reversible:

- **journald & JVM heap:** Remove the script from `/data/on_boot.d/` and reboot. The overlay filesystem resets the config files to stock on the next UniFi OS upgrade (or revert manually - see each script's docs).
- **Fan tuning:** `systemctl restart uhwd` immediately resets to defaults. Or remove and reboot.
- **MongoDB SSD:** `umount /data/unifi/data/db && systemctl restart unifi` puts MongoDB back on eMMC immediately.

## Contributing

This repo is in private beta. If you're testing:

1. **Start with one script** - don't deploy everything at once
2. **Monitor for 24+ hours** before adding another script
3. **Report back** with your gateway model, UniFi OS version, UniFi Network version, and results
4. If something breaks, document what happened and how you recovered

## License

MIT License. See [LICENSE](LICENSE).
