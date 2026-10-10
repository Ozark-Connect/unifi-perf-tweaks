# fan-control-tuning

**Script:** [`scripts/15-fan-control-tuning.sh`](../scripts/15-fan-control-tuning.sh)
**Compatibility:** Any UCG model with `uhwd`/`ufcd` + SDB fan control (UCG-Fiber, UCG-Max, others with PID-controlled fans)
**Risk level:** Low - uses the official SDB API, non-persistent (resets when the fan daemon restarts)

## Problem

UniFi Cloud Gateways ship with extremely conservative fan controller setpoints. Typical defaults:

| Category | Default Setpoint | Problem |
|---|---|---|
| CPU | 100C | Fan barely runs; CPU idles at 68C+ |
| HDD | 68C | Marginal protection for NVMe/eMMC |
| rtl8372 | 109C | 10G switch chip gets no active cooling |
| rtl8261 | 103C | SFP+ PHY gets no active cooling |

With a low standby PWM (20), the fan frequently cycles fully off then back on.

### How This Differs From Other Fan Scripts

Most community fan control scripts run a background loop that continuously reads temperatures and writes PWM values. This creates:
- Constant eMMC writes from logging
- A process fighting `uhwd` for PWM control
- Unnecessary complexity

This script takes a different approach: it tunes the **existing** PID controller's setpoints via the official SDB API. One-shot at boot, no background process, no eMMC wear, no fighting with uhwd. The PID controller does what it was designed to do - just with better targets.

## Which daemon owns the fan loop

This changed in UniFi OS 6.0 and it is the single most important detail in this tweak.

| UniFi OS | Daemon running the PID loop | Notes |
|---|---|---|
| 5.1.x and earlier | `uhwd` | `ufcd` does not exist in the image at all |
| 6.0.x and later | **`ufcd`** ("UI fan control daemon") | `uhwd` no longer writes PWM |

On 6.0.x the fan loop lives in `ufcd.service`, which loads `ustd/hwmon/fan_ctrl_sm.so`. `uhwd` still runs and still reports thermal telemetry, but it never touches `pwm1`.

Writing `config.fan` to SDB never triggers a re-read on its own, so the **owning** daemon has to be restarted. Restarting the wrong one fails silently in a way that is easy to miss:

- The SDB write succeeds.
- Reading `config.fan` back shows the tuned setpoints.
- The script logs a clean `BEFORE`/`AFTER`.
- The fan keeps running on the **factory** setpoints it loaded at boot.

Confirmed on a UXG-Fiber running 6.0.5: with the CPU setpoint at 45 °C against a 58 °C CPU, the fan stayed pinned at its 15% floor (pwm 38) through a `uhwd` restart. Restarting `ufcd` instead ramped it immediately — pwm 38 → 82 → 127 → 195 → 204, and 1,927 → 7,021 rpm — then settled back to the floor once temperatures dropped below the tuned setpoints.

The script detects the owner at runtime with `systemctl cat ufcd.service`, so one script covers both generations.

## What the Script Does

1. Detects whether `ufcd` or `uhwd` owns the fan loop
2. Waits for that daemon to become active (up to 2 minutes)
3. Connects to the Status Database (SDB) via Python
4. Reads the current `config.fan` PID configuration
5. Overwrites temperature setpoints with lower values
6. Restarts **the owning daemon** so the running PID loop picks up the changes
7. Logs before/after values plus a PWM/RPM snapshot, and exits

## Configuration

Edit the variables at the top of the script:

```sh
CPU_SETPOINT=65     # Default: 100
HDD_SETPOINT=55     # Default: 68
RTL8372_SETPOINT=85 # Default: 109
RTL8261_SETPOINT=90 # Default: 103
STANDBY=20          # Default: 20 (minimum PWM, left at stock)
```

### Before You Apply: Check Your Model

**PID category names vary by gateway model.** Before applying, check what categories your gateway has:

```bash
python3 -c "
import json, threading, time
from ustd.statusdb.sdb_client import SDBClient
c = SDBClient()
t = threading.Thread(target=c.run, daemon=True); t.start(); time.sleep(1)
fan = c.get('config.fan')
print(json.dumps(fan, indent=2))
"
```

If your gateway has different category names than `cpu`, `hdd`, `rtl8372`, `rtl8261`, update the script accordingly. The script only modifies categories that exist - missing categories are safely skipped.

## PID Controller Background

The fan daemon uses a PID (Proportional-Integral-Derivative) algorithm per temperature category. Each category is an array of 11 values:

| Index | Field | Description |
|---|---|---|
| 0 | **Setpoint** | Target temperature (C) - **this is what we tune** |
| 1 | Kp | Proportional gain (-1.0) |
| 2 | Ki | Integral gain (-0.1) |
| 3 | Kd | Derivative gain (0.0) |
| 4 | auto_mode | Hardware autonomous mode |
| 5 | fan_id | Physical fan (1 or 2) |
| 6 | min_output | Minimum fan speed (0-100) |
| 7 | max_output | Maximum fan speed (0-100) |
| 8 | initial_output | Starting output |
| 9 | weight | Category priority |
| 10 | enabled | Active flag |

With negative Kp and a high setpoint, the PID output stays at minimum until temperatures approach the setpoint. Lowering the setpoint makes the PID respond at lower temperatures - the fan engages earlier and keeps components cooler.

We only change index 0 (setpoint). `standby` is written back at its stock value of 20, since its exact role is not fully established. All other PID parameters remain at factory defaults.

The factory defaults themselves live in `ustd/tools/uhardware_fan.py` as `FAN_CONFIG_MAPPING`, keyed by sysid (`a6aa` = UXG-Fiber, `a6a8` = UCG-Fiber). Read your model's stock table without guessing:

```bash
python3 -c "
import json
import ustd.tools.uhardware_fan as uf
sysid = uf.load_sysid(True)
print(sysid, json.dumps(uf.FAN_CONFIG_MAPPING[sysid], indent=2))
"
```

## Verification

```bash
# Check current fan speed
cat /sys/class/hwmon/hwmon0/pwm1        # PWM (0-255)
cat /sys/class/hwmon/hwmon0/fan1_input   # RPM

# Check script log
cat /var/log/fan-control-tuning.log

# Re-check config.fan (use the python command above)
```

**Reading `config.fan` back is not proof the setpoints are in effect.** It only proves the SDB write landed. SDB retains whatever was written whether or not any daemon consumed it.

To confirm the loop is actually live, check that the fan daemon has the state machine loaded:

```bash
# 6.0.x
sudo grep -c fan_ctrl_sm /proc/$(pgrep -x ufcd)/maps    # expect 4, not 0
# 5.1.x
sudo grep -c fan_ctrl_sm /proc/$(pgrep -x uhwd)/maps
```

The honest functional test is to temporarily set a setpoint below a component's current temperature, restart the owning daemon, and watch `pwm1` climb. Put the setpoint back afterwards.

A low PWM on its own is **not** a failure. When every component sits below its setpoint the PID correctly parks the fan at its floor (`min_output` 15% = pwm 38 on UCG/UXG-Fiber). Judge the result against the temperatures, not against the PWM alone.

### Measured Results (UCG-Fiber)

| PWM | RPM | Thermal Impact |
|---|---|---|
| 0 (off) | 0 | Passive equilibrium ~68C |
| 89 (35%) | ~3,810 | Steady state ~52-55C |
| 128 (50%) | ~5,067 | Steady state ~53-58C |
| 255 (100%) | ~7,927 | Maximum cooling |

## Reverting

Remove the boot script and reboot - the fan daemon re-initializes `config.fan` to stock defaults during a full boot:

```bash
rm /data/on_boot.d/15-fan-control-tuning.sh
reboot
```

**Note:** restarting the fan daemon alone does **not** clear tuned values from the SDB. The SDB retains PID setpoints across daemon restarts. To revert without rebooting, write stock defaults back to the SDB explicitly:

```bash
python3 << 'EOF'
import threading, time
from ustd.statusdb.sdb_client import SDBClient
c = SDBClient()
t = threading.Thread(target=c.run, daemon=True)
t.start()
time.sleep(1)
fan = c.get("config.fan")
pid = fan.get("PID", {})
stock = {"cpu": 100, "hdd": 68, "rtl8372": 109, "rtl8261": 103}
for k, v in stock.items():
    if k in pid:
        pid[k][0] = v
fan["standby"] = 20
c.update("config.fan", fan)
time.sleep(1)
EOF
systemctl restart "$(systemctl cat ufcd.service >/dev/null 2>&1 && echo ufcd || echo uhwd)"
```

*Updated May 2026: previous versions stated `systemctl restart uhwd` was sufficient to revert. Testing on firmware 5.0.16 confirmed the SDB retains tuned values across uhwd restarts. A full reboot or explicit SDB reset is required.*
