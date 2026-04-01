# fan-control-tuning

**Script:** [`scripts/15-fan-control-tuning.sh`](../scripts/15-fan-control-tuning.sh)
**Compatibility:** Any UCG model with `uhwd` + SDB fan control (UCG-Fiber, UCG-Max, others with PID-controlled fans)
**Risk level:** Low - uses the official SDB API, non-persistent (resets on uhwd restart)

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

## What the Script Does

1. Waits for `uhwd.service` to start (up to 2 minutes)
2. Connects to the Status Database (SDB) via Python
3. Reads the current `config.fan` PID configuration
4. Overwrites temperature setpoints with lower values
5. Restarts `uhwd` so the running PID loop picks up the changes
6. Logs before/after values and exits

## Configuration

Edit the variables at the top of the script:

```sh
CPU_SETPOINT=65     # Default: 100
HDD_SETPOINT=55     # Default: 68
RTL8372_SETPOINT=85 # Default: 109
RTL8261_SETPOINT=80 # Default: 103
STANDBY=30          # Default: 20 (minimum PWM)
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

`uhwd` uses a PID (Proportional-Integral-Derivative) algorithm per temperature category. Each category is an array of 11 values:

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

We only change index 0 (setpoint) and `standby` (minimum PWM). All other PID parameters remain at uhwd defaults.

## Verification

```bash
# Check current fan speed
cat /sys/class/hwmon/hwmon0/pwm1        # PWM (0-255)
cat /sys/class/hwmon/hwmon0/fan1_input   # RPM

# Check script log
cat /var/log/fan-control-tuning.log

# Re-check config.fan (use the python command above)
```

### Measured Results (UCG-Fiber)

| PWM | RPM | Thermal Impact |
|---|---|---|
| 0 (off) | 0 | Passive equilibrium ~68C |
| 89 (35%) | ~3,810 | Steady state ~52-55C |
| 128 (50%) | ~5,067 | Steady state ~53-58C |
| 255 (100%) | ~7,927 | Maximum cooling |

## Reverting

Simply restart `uhwd` - it resets `config.fan` to defaults:

```bash
systemctl restart uhwd
```

Or remove the script from `/data/on_boot.d/` and reboot.
