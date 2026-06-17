# sfp-sgmiiplus (HSGMII)

**Scripts:** [`scripts/20-sfp-sgmiiplus.sh`](../scripts/20-sfp-sgmiiplus.sh) (eth6 / Port 7), [`scripts/19-sfp-sgmiiplus-eth5.sh`](../scripts/19-sfp-sgmiiplus-eth5.sh) (eth5 / Port 6)
**Modules:** [`modules/force-uniphy1-sgmiiplus/`](../modules/force-uniphy1-sgmiiplus/) (eth6), [`modules/force-uniphy2-sgmiiplus/`](../modules/force-uniphy2-sgmiiplus/) (eth5)
**Compatibility:** UCG-Fiber / UXG-Fiber (IPQ9574, kernel 5.4.213-ui-ipq9574)
**Risk level:** Medium - kernel module, modifies SSDK internal state
**Status:** Production
**Also known as:** HSGMII (Intel/Lantiq/MaxLinear terminology for the same 2.5G SerDes mode)

## Problem

To run optimally for OLT downstream bursts, GPON ONT SFP modules need to run at 2.5G SGMII+ (HSGMII) on the UCG-Fiber / UXG-Fiber's SFP+ ports, but the QCA-SSDK's SFP EEPROM validation blocks the speed change. The SSDK reads the SFP's EEPROM, checks its advertised capabilities, and refuses to set the port to a speed the EEPROM doesn't explicitly list - even when the SFP hardware supports 2.5G just fine.

On top of that, the SSDK runs a MAC sync polling loop (`qca_hppe_mac_sw_sync_task`) that polls all switch ports every ~400ms. For any port it manages, the loop reads the link speed from a PPE hardware status register and reconfigures the MAC to match. Because SGMII+ has no 2.5G speed code in the SGMII in-band protocol, the PPE always reports 1000M for a 2.5G link. If the loop manages our port, it forces the MAC to 1G, breaking the 2.5G data path. The module excludes our port from the loop's port bitmap so the loop manages all other ports (LAN, eth5 SFP+ trunk) but never touches ours.

### Why a kernel module

The SGMII+ mode set requires kernel-level operations that can't be done from userspace. The clock tree changes (`clk_set_rate()` and `clk_set_parent()`) to switch from 125 MHz (1G) to 312.5 MHz (2.5G), the uniphy calibration that polls for a hardware calibration bit after the PLL relock, and updating SSDK internal state all require calling into the kernel directly. Raw register writes via `devmem` aren't sufficient.

## What the modules do

Both modules (uniphy1 for eth6, uniphy2 for eth5) follow the same sequence:

1. Saves the current port bitmap via `qca_ssdk_port_bmp_get()`, then stops the MAC sync polling loop briefly to prevent races during the mode change
2. Excludes the target port from the polling loop's port bitmap via `qca_ssdk_port_bmp_set()` - the loop will skip the port entirely, preventing it from forcing the MAC to 1G
3. Sets the target uniphy to SGMII+ mode by calling `adpt_hppe_uniphy_mode_set(0, uniphy_index, 0x0c)`, which sets uniphy register 0x218 to 0x50 (SGMII+ SerDes mode, vs 0x30 for SGMII), performs the PLL reset/relock sequence (reg 0x780: 0x2bf to 0x2ff, ~200ms), updates mode control register 0x46c with SGMII+ flags, runs software reset and calibration, and sets the TX/RX clocks to 312.5 MHz
4. Updates SSDK bookkeeping: sets the per-port interface mode via `_adpt_hppe_port_interface_mode_set()` and the per-uniphy global mac_mode via `ssdk_dt_global_set_mac_mode()`
5. Waits 1 second for the link to stabilize after the mode change, then restarts the polling loop - the loop now manages all other ports but skips the target port
6. Writes 2500 to the SSDK SFP PHY speed cache (`ssdk_phy_priv_data` at offset 0x690), fires `ssdk_port_link_notify` and `ubnt_send_phy_event`, then triggers an async `RTM_NEWLINK` (transient interface alias set/clear) so `ubios-udapi-server` re-reads ethtool. This makes ethtool, sysfs, UDAPI, and UniFi Network all report 2.5G
7. On unload (`rmmod`), restores the speed cache to its original value and reverts all state (uniphy mode, port interface mode, mac_mode, port bitmap), then restarts the polling loop with the full port set

The mode set causes the target interface to flap briefly (~300ms) while the PLL relocks.

### Port-to-module mapping

| Module | Uniphy | SSDK port | Interface | Physical label | Boot script |
|---|---|---|---|---|---|
| `force_uniphy1_sgmiiplus` | 1 | 5 | eth6 | Port 7 (SFP+) | `20-sfp-sgmiiplus.sh` |
| `force_uniphy2_sgmiiplus` | 2 | 6 | eth5 | Port 6 (SFP+) | `19-sfp-sgmiiplus-eth5.sh` |

Loading both modules simultaneously is **not currently supported**. Each module independently saves and restores the full polling loop port bitmap. The second module to load would save the first module's already-modified bitmap as "original," corrupting the restore state. Supporting dual-port SGMII+ requires coordinated bitmap manipulation (each module toggling only its own port bit) — tracked as future work.

## Important caveats

### Port bitmap exclusion

Each module removes its target port from the SSDK's polling loop port bitmap. This is a runtime-only change to a value in kernel memory - it persists as long as the module is loaded and is restored on unload. The polling loop continues managing all other ports for link state, speed/duplex sync, and flow control.

The bitmap exclusion is necessary because the loop reads link speed from a PPE hardware register that always reports 1000M for SGMII+ links (the SGMII in-band protocol has no 2.5G speed code). If the loop managed the port, it would force the MAC to 1G on every link-up event, creating a MAC/SerDes speed mismatch that kills the data path.

Default port bitmap is `0x62` (ports 1, 5, 6). The uniphy1 module clears bit 5 (port 5 / eth6), the uniphy2 module clears bit 6 (port 6 / eth5). Only one module should be loaded at a time — see the dual-port caveat above.

### SSDK bookkeeping

Each module also writes to two SSDK internal data structures (per-port interface mode and per-uniphy mac_mode). These are the same structures the SSDK itself writes during normal port initialization - the module sets them to SGMII+ values so any SSDK code path that checks the port mode sees a consistent state.

### Version history

v1 stopped the MAC sync polling loop entirely. This caused forwarding drops on eth5 and flow control loss during UniFi Network config pushes (IDS/IPS toggle, etc.), because the loop manages link state for all ports. v2 updated bookkeeping and restarted the loop, but the loop's link-up speed sync (reading 1000M from PPE) broke the 2.5G data path on cold starts (SFP reboot, gateway reboot, DSMP restart). v3 excludes port 5/eth6 from the bitmap, keeping the loop running for all other ports while preventing it from touching our SGMII+ port. v4 (current) adds speed reporting: writes 2500 to the SSDK SFP PHY speed cache so ethtool/sysfs/UDAPI/UniFi Network all report 2.5G instead of the misleading 1000M. If you are running v1, v2, or v3, upgrade.

### Symbol resolution

The module resolves three symbols from `qca-ssdk.ko` at load time. Their addresses change across UniFi OS versions even though the kernel stays the same - Ubiquiti ships a different `qca-ssdk.ko` build with each release:

| Symbol | Type | Resolution | Purpose |
|---|---|---|---|
| `adpt_hppe_uniphy_mode_set` | local (t) | kallsyms | Uniphy SerDes mode set |
| `_adpt_hppe_port_interface_mode_set` | local (t) | kallsyms | Per-port interface mode bookkeeping |
| `ssdk_dt_global_set_mac_mode` | local (t) | kallsyms | Per-uniphy global mac_mode bookkeeping |
| `qca_ssdk_port_bmp_get` | local (t) | kallsyms | Read polling loop port bitmap |
| `qca_ssdk_port_bmp_set` | local (t) | kallsyms | Write polling loop port bitmap |
| `ssdk_phy_priv_data_get` | local (t) | kallsyms | SSDK private data (SFP PHY speed cache) |
| `ssdk_port_link_notify` | local (t) | kallsyms | Link state notifier chain |
| `ubnt_send_phy_event` | local (t) | kallsyms | UniFi PHY event netlink notification |

| UniFi OS | Kernel | `adpt_hppe_uniphy_mode_set` address |
|---|---|---|
| 5.0.10 | 5.4.213-ui-ipq9574 | `ffffffc008935300` |
| 5.0.16 | 5.4.213-ui-ipq9574 | `ffffffc00893e300` |
| 5.1.7 EA | 5.4.213-ui-ipq9574 | `ffffffc00894e200` |
| 5.1.19 | 5.4.213-ui-ipq9574 | `ffffffc00894f200` |

The module resolves local symbols at runtime via `kallsyms_lookup_name()`, so it works across all tested OS versions without recompilation. Exported symbols (`ssdk_mac_sw_sync_work_stop`, `ssdk_mac_sw_sync_work_start`) are resolved by the kernel's normal module linker. If any lookup fails, the module refuses to load rather than guessing an address.

After loading, confirm the symbols resolved:

```bash
dmesg | grep force_sgmiiplus
# "resolved all symbols via kallsyms" = good
# "lookup failed" = module refused to load
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
# For eth6 / Port 7:
ip link show eth6
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
# For eth5 / Port 6:
ip link show eth5
cat /sys/kernel/debug/clk/uniphy2_gcc_tx_clk/clk_rate
# Expected: 125000000 (1G) or similar

# 4. Check the kallsyms addresses for your OS version
grep -E 'adpt_hppe_uniphy_mode_set|_adpt_hppe_port_interface_mode_set|ssdk_dt_global_set_mac_mode|qca_ssdk_port_bmp' /proc/kallsyms
# All five symbols should appear. The module resolves them at runtime,
# so it should work on any OS version where they exist.
# Check dmesg after loading to confirm all resolved successfully.
```

## Deployment

The boot scripts run from `/data/on_boot.d/`, which requires udm-boot to be installed on your gateway. Without it, the scripts won't run on boot and you'll have to load the modules manually after every reboot. See [prerequisites.md](prerequisites.md) for install instructions.

The examples below show deployment for eth6 (Port 7). For eth5 (Port 6), substitute:
- Module: `force_uniphy2_sgmiiplus.ko` instead of `force_uniphy1_sgmiiplus.ko`
- Boot script: `19-sfp-sgmiiplus-eth5.sh` instead of `20-sfp-sgmiiplus.sh`
- Log file: `/var/log/sfp-sgmiiplus-eth5.log` instead of `/var/log/sfp-sgmiiplus.log`
- Clock path: `uniphy2_gcc_tx_clk` instead of `uniphy1_gcc_tx_clk`

Both modules deploy to the same directory (`/data/sfp-sgmiiplus/`). Only one module should be loaded at a time — see the port bitmap caveat above.

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
# Check module is loaded
ssh root@<gateway-ip> lsmod | grep force_uniphy1

# Verify clock rate - this is the real indicator
ssh root@<gateway-ip> cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
# 312500000 = 2.5G, 125000000 = 1G
```

### ethtool / UniFi Network speed reporting

Each module updates ethtool, sysfs, UDAPI, and the UniFi Network dashboard to report 2.5G for its target interface. This works around a cosmetic limitation of SGMII in-band signaling - the protocol has no speed code for 2.5G, so the PPE hardware always reports 1000M for SGMII+ links.

The fix writes to the SSDK's internal SFP PHY speed cache (the same cache that the "QCA SFP" fake PHY driver's `sfp_read_status()` copies into `phydev->speed`). The kernel's PHY state machine picks up the cached value within ~2 seconds, then a transient `RTM_NEWLINK` event (interface alias set/clear) signals `ubios-udapi-server` to re-read via ethtool.

After loading, all speed reporting paths should show 2500:

```bash
# eth6 (Port 7):
ethtool eth6 | grep Speed           # Speed: 2500Mb/s
cat /sys/class/net/eth6/speed       # 2500

# eth5 (Port 6):
ethtool eth5 | grep Speed           # Speed: 2500Mb/s
cat /sys/class/net/eth5/speed       # 2500
```

The uniphy clock rate and SerDes register remain the most reliable ways to confirm the actual hardware speed:

```bash
# eth6 / uniphy1:
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
busybox devmem 0x07A10218 32

# eth5 / uniphy2:
cat /sys/kernel/debug/clk/uniphy2_gcc_tx_clk/clk_rate
busybox devmem 0x07A20218 32

# 312500000 / 0x00000050 = SGMII+ (2.5G)
# 125000000 / 0x00000030 = SGMII (1G)
```

## Verification

After a module loads (either manually or on boot):

```bash
# Clock rate - the real speed indicator
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate   # eth6
cat /sys/kernel/debug/clk/uniphy2_gcc_tx_clk/clk_rate   # eth5

# Modules loaded
lsmod | grep force_uniphy

# Boot script logs
cat /var/log/sfp-sgmiiplus.log        # eth6
cat /var/log/sfp-sgmiiplus-eth5.log   # eth5

# Kernel log (module load messages)
dmesg | grep force_sgmiiplus
```

## Reverting

### Immediate (until next reboot)

Unloading a module reverts its uniphy to SGMII 1G and restarts the MAC sync polling loop:

```bash
rmmod force_uniphy1_sgmiiplus   # eth6
rmmod force_uniphy2_sgmiiplus   # eth5
```

Verify the revert:

```bash
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate   # eth6
cat /sys/kernel/debug/clk/uniphy2_gcc_tx_clk/clk_rate   # eth5
# Expected: 125000000
```

### Permanent

Remove the boot script so it doesn't reload on next boot, then unload:

```bash
# eth6:
rm /data/on_boot.d/20-sfp-sgmiiplus.sh
rmmod force_uniphy1_sgmiiplus

# eth5:
rm /data/on_boot.d/19-sfp-sgmiiplus-eth5.sh
rmmod force_uniphy2_sgmiiplus
```

Optionally clean up the module files:

```bash
rm -rf /data/sfp-sgmiiplus
```

## Cross-compiling

The UCG-Fiber / UXG-Fiber has `make` but no gcc and no kernel headers, so the modules have to be cross-compiled on another machine.

### Requirements

You need `aarch64-linux-gnu-gcc` (or any ARM64 cross-compiler) and a kernel source tree matching `5.4.213-ui-ipq9574` with a matching `.config`.

Ubiquiti does not publicly distribute kernel source. Your options are to extract `/proc/config.gz` from the gateway (if available) and build a matching 5.4 source tree, or use a Docker-based cross-compilation environment with the extracted config.

### Build

```bash
# eth6 / Port 7:
cd modules/force-uniphy1-sgmiiplus/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source

# eth5 / Port 6:
cd modules/force-uniphy2-sgmiiplus/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source
```

Since the modules resolve local symbols via `kallsyms_lookup_name()` at runtime, a rebuilt module should work across OS versions without address changes. After a firmware update, just verify the modules still load and resolve correctly via `dmesg`.
