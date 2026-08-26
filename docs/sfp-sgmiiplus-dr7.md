# sfp-sgmiiplus-dr7 (HSGMII on Dream Router 7)

**Script:** [`scripts/20-sfp-sgmiiplus-dr7.sh`](../scripts/20-sfp-sgmiiplus-dr7.sh) (eth4 / SFP port)
**Module:** [`modules/force-uniphy1-sgmiiplus-dr7/`](../modules/force-uniphy1-sgmiiplus-dr7/)
**Compatibility:** UniFi Dream Router 7 (DR7, IPQ5322, kernel 5.4.213-ui-ipq5322-wireless)
**Risk level:** Medium - kernel module, modifies SSDK internal state
**Status:** Beta - module loads correctly, clock/SerDes/speed reporting verified at 2.5G. Full end-to-end GPON throughput test pending (fiber connection not yet active; expected ~2 weeks).
**Also known as:** HSGMII (Intel/Lantiq/MaxLinear terminology for the same 2.5G SerDes mode)

---

## Background / Porting notes

This module is a port of the UCG-Fiber / UXG-Fiber `force_uniphy1_sgmiiplus` module (IPQ9574)
to the **UniFi Dream Router 7** (IPQ5322). The IPQ5322 uses the same QCA-SSDK and the same
kernel version (5.4.213), but has a different internal port topology that required non-trivial
changes to make the port work correctly.

The key differences discovered during porting are documented in the table below and explained
in detail in the rest of this file.

---

## Problem

Same root cause as the UCG-Fiber / UXG-Fiber: the SSDK's SFP EEPROM validation blocks the
speed change to 2.5G, and the MAC sync polling loop continuously resets uniphy1 back to
SGMII 1G.

On the DR7 specifically, the MAC sync loop resets uniphy1 **every ~5 seconds** via
`__adpt_hppe_uniphy_sgmii_mode_set` (visible in dmesg). This is more aggressive than on the
UCG/UXG-Fiber and is caused by the RTL8261 PHY in the SFP port triggering repeated
re-initialization. Without the bitmap exclusion, any 2.5G SerDes configuration is overwritten
within seconds.

---

## Key differences from UCG-Fiber / UXG-Fiber

| Parameter | UCG/UXG-Fiber (IPQ9574) | DR7 (IPQ5322) |
|---|---|---|
| Kernel | 5.4.213-ui-ipq9574 | 5.4.213-ui-ipq5322-wireless |
| SFP interface | eth6 (Port 7) / eth5 (Port 6) | **eth4** |
| Uniphy index | 1 (eth6) / 2 (eth5) | **1** |
| SSDK port ID | 5 (eth6) / 6 (eth5) | **2** |
| Default port bitmap | 0x62 (ports 1, 5, 6) | **0x06 (ports 1, 2)** |
| Bitmap after exclusion | 0x42 / 0x22 | **0x02** |
| NSS dataplane ports | dp1–dp6 | **dp1, dp2 only** |
| SFP PHY chip | — | RTL8261 (causes aggressive re-init loop) |

### Why SSDK_PORT_ID is 2, not 5

The DR7 has only two NSS dataplane ports (dp1, dp2), compared to six on the UCG/UXG-Fiber.
`eth4` maps to `dp1` (device-tree node `3a504000.dp1`), which is **SSDK port 2** on IPQ5322.
This was confirmed via dmesg:

```
qca_mac_port_status_init: port 2 is RTL8261, force to enable flowctrl
```

Using the wrong port ID (e.g. 5 as in the original module) would remove a non-existent port
from the bitmap and leave the actual SFP port unprotected — the MAC sync loop would continue
resetting it every ~5 seconds.

### Why the bitmap is 0x06

The MAC sync loop on the DR7 only manages Port 1 and Port 2 (bitmap `0x06`). After excluding
Port 2 (eth4/SFP), the remaining bitmap is `0x02` — the loop continues managing Port 1 (the
internal switch / LAN ports) but no longer touches the SFP port.

---

## What the module does

Same sequence as the original UCG-Fiber module, adapted for DR7 port topology:

1. Reads the current port bitmap via `qca_ssdk_port_bmp_get()` (expected: `0x06`)
2. Stops the MAC sync polling loop briefly to prevent races
3. Removes Port 2 from the bitmap (`0x06 → 0x02`) via `qca_ssdk_port_bmp_set()`
4. Calls `adpt_hppe_uniphy_mode_set(0, 1, 0x0c)` to set uniphy1 to SGMII+ mode:
   - Sets SerDes register 0x07A10218 from `0x30` (SGMII 1G) to `0x50` (SGMII+)
   - Performs PLL reset/relock (~200ms)
   - Sets TX/RX clocks to 312.5 MHz
5. Updates SSDK bookkeeping via `_adpt_hppe_port_interface_mode_set()` and `ssdk_dt_global_set_mac_mode()`
6. Waits 1 second for link stabilization, then restarts the polling loop (Port 2 excluded)
7. Writes 2500 to the SSDK SFP PHY speed cache, fires `ssdk_port_link_notify` and
   `ubnt_send_phy_event`, triggers RTM_NEWLINK so ethtool/sysfs/UDAPI report 2500Mb/s
8. On `rmmod`: restores speed cache, reverts uniphy1 to SGMII 1G, restores bitmap, restarts loop

---

## Verification (hardware confirmed)

The following was verified on a DR7 running UniFi OS with kernel 5.4.213-ui-ipq5322-wireless:

```bash
# All three should show 2.5G after module load:
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate   # 312500000
busybox devmem 0x07A10218 32                             # 0x00000050
ethtool eth4 | grep Speed                               # Speed: 2500Mb/s

# Internet connectivity confirmed working after module load:
ping -c 3 8.8.8.8                                       # 0% packet loss

# rmmod reverts correctly:
# busybox devmem 0x07A10218 32                          # 0x00000030 (back to SGMII 1G)
```

dmesg output after successful load:
```
force_sgmiiplus: resolved all symbols via kallsyms
force_sgmiiplus: current port bitmap: 0x6, will set: 0x2
force_sgmiiplus: port bitmap 0x6 -> 0x2 (port 2 excluded)
force_sgmiiplus: uniphy1 set to SGMII+ 2.5G (ret=0)
force_sgmiiplus: loop restarted (port 2 excluded from bitmap)
force_sgmiiplus: priv_data base addr: 0xffffff80bb220000
force_sgmiiplus: speed cache: 1000 -> 2500, duplex cache: 1 -> 1
force_sgmiiplus: ssdk_port_link_notify fired
force_sgmiiplus: ubnt_send_phy_event fired
force_sgmiiplus: speed reporting update triggered
```

> **Note:** Full end-to-end GPON throughput testing (2.5G downstream via ONT SFP) has not yet
> been performed — the fiber connection is not yet active. Hardware-level verification (clock
> rate, SerDes register, ethtool speed, internet connectivity) all pass. GPON test expected
> within ~2 weeks; this note will be updated with results.

---

## Symbol resolution

All symbols are resolved the same way as the original module via `kallsyms_lookup_name()` at
load time. Confirmed addresses on this firmware version:

| Symbol | Address |
|---|---|
| `adpt_hppe_uniphy_mode_set` | `ffffffc008a1dac8` |
| `_adpt_hppe_port_interface_mode_set` | `ffffffc008a088b8` |
| `ssdk_dt_global_set_mac_mode` | `ffffffc008ac63bc` |
| `qca_ssdk_port_bmp_get` | `ffffffc008a5c150` |
| `qca_ssdk_port_bmp_set` | `ffffffc008a5c130` |
| `ssdk_phy_priv_data_get` | `ffffffc008acacf0` |
| `ssdk_port_link_notify` | `ffffffc008a965a4` |
| `ubnt_send_phy_event` | `ffffffc008a09478` |

Addresses will differ across firmware versions — the module resolves them at runtime so no
recompilation is needed after firmware updates. After any update, verify with:

```bash
dmesg | grep force_sgmiiplus
# "resolved all symbols via kallsyms" = good
# "kallsyms lookup failed" = module refused to load, check dmesg for which symbol is missing
```

---

## Pre-check

```bash
# 1. Confirm kernel version
uname -r
# Expected: 5.4.213-ui-ipq5322-wireless

# 2. Confirm qca-ssdk is loaded
lsmod | grep qca_ssdk

# 3. Check current state
ip link show eth4
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate   # Expected: 125000000
busybox devmem 0x07A10218 32                             # Expected: 0x00000030

# 4. Confirm all symbols exist
grep -E 'adpt_hppe_uniphy_mode_set|_adpt_hppe_port_interface_mode_set|ssdk_dt_global_set_mac_mode|qca_ssdk_port_bmp|ssdk_phy_priv_data|ssdk_port_link_notify|ubnt_send_phy_event' /proc/kallsyms
# All 8 symbols must appear
```

---

## Deployment

Requires `udm-boot` to be installed for the boot script to run automatically.

### 1. Copy module to DR7

```bash
ssh root@<dr7-ip> "mkdir -p /data/sfp-sgmiiplus"
scp modules/force-uniphy1-sgmiiplus-dr7/force_uniphy1_sgmiiplus_dr7.ko \
    root@<dr7-ip>:/data/sfp-sgmiiplus/
```

### 2. Copy boot script

```bash
scp scripts/20-sfp-sgmiiplus-dr7.sh root@<dr7-ip>:/data/on_boot.d/20-sfp-sgmiiplus.sh
ssh root@<dr7-ip> "chmod +x /data/on_boot.d/20-sfp-sgmiiplus.sh"
```

### 3. Test run

```bash
ssh root@<dr7-ip> insmod /data/sfp-sgmiiplus/force_uniphy1_sgmiiplus_dr7.ko
ssh root@<dr7-ip> dmesg | grep force_sgmiiplus
ssh root@<dr7-ip> cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate  # 312500000
ssh root@<dr7-ip> busybox devmem 0x07A10218 32                            # 0x00000050
ssh root@<dr7-ip> ethtool eth4 | grep Speed                              # 2500Mb/s
```

---

## Cross-compiling

The DR7 has no gcc and no kernel headers. Cross-compile on an x86 machine:

### Requirements

- `aarch64-linux-gnu-gcc` (Ubuntu: `sudo apt install gcc-aarch64-linux-gnu`)
- Kernel source tree matching `5.4.213-ui-ipq5322-wireless`
- `.config` extracted from the DR7: `ssh root@<dr7-ip> "zcat /proc/config.gz" > .config`

### Build

```bash
# Prepare kernel source (once)
cd /path/to/linux-5.4.213
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- prepare
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_prepare

# Build module
cd modules/force-uniphy1-sgmiiplus-dr7/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/linux-5.4.213

# Verify architecture
file force_uniphy1_sgmiiplus_dr7.ko
# Expected: ELF 64-bit LSB relocatable, ARM aarch64
```

---

## Reverting

```bash
# Immediate revert
rmmod force_uniphy1_sgmiiplus_dr7
busybox devmem 0x07A10218 32   # Should show 0x00000030 (back to SGMII 1G)

# Permanent - remove boot script then unload
rm /data/on_boot.d/20-sfp-sgmiiplus.sh
rmmod force_uniphy1_sgmiiplus_dr7

# Optional cleanup
rm -rf /data/sfp-sgmiiplus
```
