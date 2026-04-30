# sfp-sgmiiplus

**Script:** [`scripts/20-sfp-sgmiiplus.sh`](../scripts/20-sfp-sgmiiplus.sh)
**Module:** [`modules/force-uniphy1-sgmiiplus/`](../modules/force-uniphy1-sgmiiplus/)
**Compatibility:** UCG-Fiber / UXG-Fiber (IPQ9574, kernel 5.4.213-ui-ipq9574)
**Risk level:** Medium - kernel module, stops a global polling loop
**Status:** Testing

## Problem

GPON ONT SFP modules need to run at 2.5G on the UCG-Fiber / UXG-Fiber's 2nd SFP+ port (eth6 / Port 7), but the QCA-SSDK's SFP EEPROM validation blocks the speed change. The SSDK reads the SFP's EEPROM, checks its advertised capabilities, and refuses to set the port to a speed the EEPROM doesn't explicitly list - even when the SFP hardware supports 2.5G just fine.

On top of that, the SSDK runs a MAC sync polling loop (`qca_hppe_mac_sw_sync_task`) every ~12 seconds that re-reads the SFP EEPROM and forces the port back to SGMII 1G. Even if you could set 2.5G through the normal path, the polling loop would revert it within seconds.

### Why a kernel module

The SGMII+ mode set requires kernel-level operations that can't be done from userspace. The clock tree changes (`clk_set_rate()` and `clk_set_parent()`) to switch from 125 MHz (1G) to 312.5 MHz (2.5G), the uniphy calibration that polls for a hardware calibration bit after the PLL relock, and stopping the MAC sync polling loop all require calling into the kernel directly. Raw register writes via `devmem` aren't sufficient.

## What the module does

1. Stops the MAC sync polling loop by calling `ssdk_mac_sw_sync_work_stop()` so the SSDK can't revert the mode change
2. Sets uniphy1 to SGMII+ mode by calling `adpt_hppe_uniphy_mode_set(0, 1, 0x0c)`, which sets uniphy register 0x218 to 0x50 (SGMII+ SerDes mode, vs 0x30 for SGMII), performs the PLL reset/relock sequence (reg 0x780: 0x2bf to 0x2ff, ~200ms), updates mode control register 0x46c with SGMII+ flags, runs software reset and calibration, and sets the TX/RX clocks to 312.5 MHz
3. On unload (`rmmod`), reverts to SGMII 1G (mode 0x0f) and restarts the polling loop

The mode set causes eth6 to flap briefly (~300ms) while the PLL relocks.

## Important caveats

### This is for the 2nd SFP+ port only

This module targets uniphy1 = eth6 = Port 7, the 2nd SFP+ port on the UCG-Fiber / UXG-Fiber. It does not touch the 1st SFP+ port (uniphy0).

### MAC sync polling is global

Stopping the MAC sync polling loop is a global operation - it stops the polling task for the entire SSDK, not just uniphy1. This may affect the other SFP+ port's ability to recover from link drops, detect hot swaps (SFP module insertion/removal), or re-negotiate after a fiber disconnect/reconnect.

We have not tested those scenarios. If you rely on the other SFP+ port for critical traffic and need it to recover gracefully from link events, understand that this module may compromise that ability. For a permanently seated SFP that doesn't get swapped, this is a non-issue.

### Symbol resolution

`adpt_hppe_uniphy_mode_set` is a local (unexported) symbol in `qca-ssdk.ko`. Its address changes across UniFi OS versions even though the kernel stays the same - Ubiquiti ships a different `qca-ssdk.ko` build with each release:

| UniFi OS | Kernel | `adpt_hppe_uniphy_mode_set` address |
|---|---|---|
| 5.0.10 | 5.4.213-ui-ipq9574 | `ffffffc008935300` |
| 5.0.16 | 5.4.213-ui-ipq9574 | `ffffffc00893e300` |
| 5.1.7 EA | 5.4.213-ui-ipq9574 | `ffffffc00894e200` |

The module resolves the correct address at runtime via `kallsyms_lookup_name()`, so it works across all tested OS versions without recompilation. We've confirmed this on UniFi OS 5.0.10 - `kallsyms_lookup_name` resolves successfully every time. If the lookup ever fails (which we haven't seen), the module refuses to load rather than guessing an address.

After loading, confirm the symbol resolved:

```bash
dmesg | grep force_sgmiiplus
# "resolved adpt_hppe_uniphy_mode_set at <addr> via kallsyms" = good
# "kallsyms_lookup_name failed" = module refused to load
```

After any firmware update, verify the module still resolves and loads correctly.

## Pre-check

Before deploying, SSH into your gateway and verify:

```bash
# 1. Confirm you're on a UCG-Fiber / UXG-Fiber with the expected kernel
uname -r
# Expected: 5.4.213-ui-ipq9574

# 2. Confirm qca-ssdk is loaded (required dependency)
lsmod | grep qca_ssdk
# Should show qca_ssdk with a nonzero size

# 3. Confirm the target port exists and check current state
ip link show eth6
# Should show eth6 (may be UP or DOWN depending on SFP state)

# 4. Check current clock rate (baseline - should be 125 MHz = 1G, or 0 if no SFP)
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
# Expected: 125000000 (or similar)

# 5. Check the kallsyms address for your OS version
grep adpt_hppe_uniphy_mode_set /proc/kallsyms
# Compare against the table above. If you're on an OS version not listed,
# the module should still work via kallsyms_lookup_name() at runtime,
# but check dmesg after loading to confirm it resolved successfully.
```

## Deployment

### 1. Copy module to gateway

```bash
# From your local machine - create the directory and copy the .ko
ssh root@<gateway-ip> "mkdir -p /data/sfp-sgmiiplus"
scp modules/force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.ko \
    root@<gateway-ip>:/data/sfp-sgmiiplus/
```

### 2. Copy boot script

```bash
scp scripts/20-sfp-sgmiiplus.sh root@<gateway-ip>:/data/on_boot.d/
ssh root@<gateway-ip> "chmod +x /data/on_boot.d/20-sfp-sgmiiplus.sh"
```

### 3. Test run

```bash
# Load the module (expect a brief ~300ms link flap on eth6)
ssh root@<gateway-ip> /data/on_boot.d/20-sfp-sgmiiplus.sh

# Check the log
ssh root@<gateway-ip> cat /var/log/sfp-sgmiiplus.log

# Verify clock rate switched to 2.5G
ssh root@<gateway-ip> cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
# Expected: 312500000
```

### 4. Verify link

```bash
# Check eth6 link state and speed
ssh root@<gateway-ip> "ethtool eth6 | grep -i speed"
# Expected: Speed: 2500Mb/s

# Check module is loaded
ssh root@<gateway-ip> lsmod | grep force_uniphy1
```

## Verification

After the module loads (either manually or on boot):

```bash
# Clock rate - 312500000 = 2.5G, 125000000 = 1G
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate

# Module loaded
lsmod | grep force_uniphy1_sgmiiplus

# Boot script log
cat /var/log/sfp-sgmiiplus.log

# Kernel log (module load messages)
dmesg | grep force_sgmiiplus
```

## Reverting

### Immediate (until next reboot)

Unloading the module reverts uniphy1 to SGMII 1G and restarts the MAC sync polling loop:

```bash
rmmod force_uniphy1_sgmiiplus
```

Verify the revert:

```bash
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
# Expected: 125000000
```

### Permanent

Remove the boot script so it doesn't reload on next boot, then unload:

```bash
rm /data/on_boot.d/20-sfp-sgmiiplus.sh
rmmod force_uniphy1_sgmiiplus
```

Optionally clean up the module files:

```bash
rm -rf /data/sfp-sgmiiplus
```

## Cross-compiling

The UCG-Fiber / UXG-Fiber has `make` but no gcc and no kernel headers, so the module has to be cross-compiled on another machine.

### Requirements

You need `aarch64-linux-gnu-gcc` (or any ARM64 cross-compiler) and a kernel source tree matching `5.4.213-ui-ipq9574` with a matching `.config`.

Ubiquiti does not publicly distribute kernel source. Your options are to extract `/proc/config.gz` from the gateway (if available) and build a matching 5.4 source tree, or use a Docker-based cross-compilation environment with the extracted config.

### Build

```bash
cd modules/force-uniphy1-sgmiiplus/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source
```

Since the module resolves `adpt_hppe_uniphy_mode_set` via `kallsyms_lookup_name()` at runtime, a rebuilt module should work across OS versions without address changes. After a firmware update, just verify the module still loads and resolves correctly via `dmesg`.
