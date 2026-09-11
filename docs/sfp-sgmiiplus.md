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

Both modules save the SSDK state, exclude their target port from the MAC-sync
bitmap, program SGMII+ mode, update the speed cache, and restore the saved
state on unload.

The UniPHY1/eth6 module additionally makes the complete host-side transition:

1. It uses `adpt_hppe_port_interface_mode_set()` to force SGMII+, so an SFP
   EEPROM event cannot silently restore the port to 1000BASE-X.
2. It disables the MAC path, programs the UniPHY and APPE XGMAC path, then
   brings the path back at 2500/full.
3. A one-second monitor checks the physical mode, forced-interface flag,
   XGMAC selection, global mode, and bitmap. On drift it quiesces the path,
   repeats the vendor transition, and resynchronizes host link state from PCS.
4. On unload it stops the monitor before restoring the original interface,
   mode, cache, and bitmap state.

The UniPHY2/eth5 module remains a one-shot transition. Loading or recovering
the UniPHY1 module briefly flaps eth6 while the SerDes and MAC path are
reconfigured.

### Port-to-module mapping

| Module | Uniphy | SSDK port | Interface | Physical label | Boot script |
|---|---|---|---|---|---|
| `force_uniphy1_sgmiiplus` | 1 | 5 | eth6 | Port 7 (SFP+) | `20-sfp-sgmiiplus.sh` |
| `force_uniphy2_sgmiiplus` | 2 | 6 | eth5 | Port 6 (SFP+) | `19-sfp-sgmiiplus-eth5.sh` |

Loading both modules simultaneously is **not currently supported**. Each module independently saves and restores the full polling loop port bitmap. The second module to load would save the first module's already-modified bitmap as "original," corrupting the restore state. Supporting dual-port SGMII+ requires coordinated bitmap manipulation (each module toggling only its own port bit) — tracked as future work.

## Important caveats

### Port bitmap exclusion

Each module removes its target port from the SSDK's polling loop port bitmap. This is a runtime-only change to a value in kernel memory - it persists as long as the module is loaded and is restored on unload. The polling loop continues managing all other ports for link state, speed/duplex sync, and flow control. The UniPHY1 monitor also re-clears the eth6 bit if another SSDK path restores it.

The bitmap exclusion is necessary because the loop reads link speed from a PPE hardware register that always reports 1000M for SGMII+ links (the SGMII in-band protocol has no 2.5G speed code). If the loop managed the port, it would force the MAC to 1G on every link-up event, creating a MAC/SerDes speed mismatch that kills the data path.

Default port bitmap is `0x62` (ports 1, 5, 6). The uniphy1 module clears bit 5 (port 5 / eth6), the uniphy2 module clears bit 6 (port 6 / eth5). Only one module should be loaded at a time — see the dual-port caveat above.

### SSDK bookkeeping

Each module writes SSDK interface and global-mode state so readers see a
consistent SGMII+ configuration. UniPHY1 uses the public interface-mode setter
to retain the forced mode, programs the APPE MAC mux to XGMAC, and keeps the
link, speed, and duplex caches synchronized from PCS rather than GPON RX_LOS.

### Symbol resolution

The modules resolve private symbols from `qca-ssdk.ko` at load time. Their addresses can change across UniFi OS builds:

| Symbol | Type | Resolution | Purpose |
|---|---|---|---|
| `adpt_hppe_uniphy_mode_set` | local (t) | kallsyms | UniPHY SerDes mode set |
| `adpt_hppe_port_interface_mode_set`, `_adpt_hppe_port_interface_mode_set`, `adpt_hppe_port_interface_mode_get` | local (t) | kallsyms | Forced interface mode and saved-mode restoration |
| `ssdk_dt_global_get_mac_mode`, `ssdk_dt_global_set_mac_mode` | local (t) | kallsyms | Per-UniPHY global-mode state |
| `qca_ssdk_port_bmp_get` | local (t) | kallsyms | Read polling loop port bitmap |
| `qca_ssdk_port_bmp_set` | local (t) | kallsyms | Write polling loop port bitmap |
| `adpt_hppe_port_mux_mac_type_set`, `qca_hppe_port_mac_type_get` | local (t) | kallsyms | APPE GMAC/XGMAC transition and verification |
| `hppe_uniphy_channel0_input_output_6_get`, `hppe_uniphy_phy_mode_ctrl_get` | local (t) | kallsyms | PCS link and physical-mode reads |
| `ssdk_phy_priv_data_get` | local (t) | kallsyms | SSDK link, speed, and duplex caches |
| `ssdk_port_link_notify` | local (t) | kallsyms | Link state notifier chain |
| `ubnt_send_phy_event` | local (t) | kallsyms | UniFi PHY event netlink notification |

| UniFi OS | Kernel | `adpt_hppe_uniphy_mode_set` address |
|---|---|---|
| 5.0.10 | 5.4.213-ui-ipq9574 | `ffffffc008935300` |
| 5.0.16 | 5.4.213-ui-ipq9574 | `ffffffc00893e300` |
| 5.1.7 EA | 5.4.213-ui-ipq9574 | `ffffffc00894e200` |
| 5.1.19 | 5.4.213-ui-ipq9574 | `ffffffc00894f200` |
| 5.1.21 EA | 5.4.213-ui-ipq9574 | `ffffffc00894f200` |
| 5.1.26 EA | 5.4.213-ui-ipq9574 | deferred to live test¹ |
| 5.1.28 EA | 5.4.213-ui-ipq9574 | deferred to live test¹ |
| 5.1.29 | 5.4.213-ui-ipq9574 | deferred to live test¹ |
| 5.1.30 | 5.4.213-ui-ipq9574 | deferred to live test¹ |
| 5.1.31 | 5.4.213-ui-ipq9574 | deferred to live test¹ |
| 6.0.5 EA | 5.4.213-ui-ipq9574 (rebuilt) | `ffffffc008934488` ² |

¹ The runtime `adpt_hppe_uniphy_mode_set` address — a live kallsyms value — was not captured for 5.1.26, 5.1.28, 5.1.29, 5.1.30, or 5.1.31. 5.1.26 is **field-confirmed working on UCG-Fiber and UXG-Fiber**, and 5.1.28 on the UCG-Fiber (SGMII+ module + boot tweaks, user reports + our own gateways) — our UXG-Fiber had no 5.1.28 build offered to it, going 5.1.26 → 6.0.x. But that was operational use rather than an instrumented load test, so no `dmesg`/kallsyms was recorded; 5.1.29, 5.1.30, and 5.1.31 are bench-verified only. In all five the kernel is unchanged and `qca-ssdk.ko` is code-identical to 5.1.19/5.1.21 (`.text` byte-identical, all symbols and cache offsets intact; the 5.1.28, 5.1.29, 5.1.30, and 5.1.31 `.ko`s are byte-identical to 5.1.26's), so the symbol resolves identically; the address gets recorded whenever an instrumented load test is run. See [compat-5.1.26.md](compat-5.1.26.md) / [compat-5.1.28.md](compat-5.1.28.md) / [compat-5.1.29.md](compat-5.1.29.md) / [compat-5.1.30.md](compat-5.1.30.md) / [compat-5.1.31.md](compat-5.1.31.md).

² **6.0.5 closes the kallsyms gap** — first live capture since 5.1.21, taken from a UXG-Fiber with the module loaded. All ten resolved:

| Symbol | Address | Type |
|---|---|---|
| `adpt_hppe_uniphy_mode_set` | `ffffffc008934488` | t |
| `_adpt_hppe_port_interface_mode_set` | `ffffffc00891fc08` | t |
| `ssdk_dt_global_set_mac_mode` | `ffffffc0089dcfdc` | t |
| `qca_ssdk_port_bmp_get` | `ffffffc0089713e0` | t |
| `qca_ssdk_port_bmp_set` | `ffffffc0089713c0` | t |
| `ssdk_phy_priv_data_get` | `ffffffc0089e1910` | t |
| `ssdk_port_link_notify` | `ffffffc0089ade38` | t |
| `ubnt_send_phy_event` | `ffffffc0089207a4` | t |
| `ssdk_mac_sw_sync_work_stop` | `ffffffc0089e1948` | T |
| `ssdk_mac_sw_sync_work_start` | `ffffffc0089e19a4` | T |

Note 6.0.5 shifts these addresses (the kernel and `qca-ssdk.ko` were both rebuilt under the Debian 13 / GCC 14 rebase), which is exactly why the module resolves by name at runtime rather than hardcoding addresses. See [compat-6.0.5.md](compat-6.0.5.md).

The module resolves local symbols at runtime via `kallsyms_lookup_name()`, so it works across all tested OS versions without recompilation. Exported symbols (`ssdk_mac_sw_sync_work_stop`, `ssdk_mac_sw_sync_work_start`) are resolved by the kernel's normal module linker. If any lookup fails, the module refuses to load rather than guessing an address.

After loading, confirm the symbols resolved:

```bash
dmesg | grep force_sgmiiplus
# "resolved symbols" = dependencies resolved
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

### UniPHY1 boot and recovery

The eth6 loader waits for `qca_ssdk`, then performs exactly one `insmod`.
Recovery stays in the module for its full lifetime: it can correct a later SFP
event that rewrites physical or MAC state without repeatedly unloading a live
WAN module. The loader requires the 312.5 MHz clock to remain stable for 15
consecutive seconds within a 60-second window. If that check fails, it leaves
the module loaded so the monitor can continue recovery.

Expected recovery evidence after a late mode reset includes:

```text
mode drift detected: ...; reasserting SGMII+
vendor mode transition complete: mode=0xc mac_type=2 speed=2500
SGMII+ mode restored after drift
PCS status ..., host link ...
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
