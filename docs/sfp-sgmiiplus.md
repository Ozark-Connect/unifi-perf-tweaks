# sfp-sgmiiplus (HSGMII)

**Scripts:** [`scripts/20-sfp-sgmiiplus.sh`](../scripts/20-sfp-sgmiiplus.sh) (eth6 / Port 7), [`scripts/19-sfp-sgmiiplus-eth5.sh`](../scripts/19-sfp-sgmiiplus-eth5.sh) (eth5 / Port 6)
**Modules:** [`modules/force-uniphy1-sgmiiplus/`](../modules/force-uniphy1-sgmiiplus/) (eth6), [`modules/force-uniphy2-sgmiiplus/`](../modules/force-uniphy2-sgmiiplus/) (eth5)
**Compatibility:** UCG-Fiber / UXG-Fiber (IPQ9574, kernel 5.4.213-ui-ipq9574)
**Risk level:** Medium - kernel module, modifies SSDK internal state
**Status:** Stable (hold mode: Testing, both ports)
**Also known as:** HSGMII (Intel/Lantiq/MaxLinear terminology for the same 2.5G SerDes mode)

## Problem

To run optimally for OLT downstream bursts, GPON ONT SFP modules need to run at 2.5G SGMII+ (HSGMII) on the UCG-Fiber / UXG-Fiber's SFP+ ports, but the QCA-SSDK's SFP EEPROM validation blocks the speed change. The SSDK reads the SFP's EEPROM, checks its advertised capabilities, and refuses to set the port to a speed the EEPROM doesn't explicitly list - even when the SFP hardware supports 2.5G just fine.

On top of that, the SSDK runs a MAC sync polling loop (`qca_hppe_mac_sw_sync_task`) that polls all switch ports every ~400ms. For any port it manages, the loop reads the link speed from a PPE hardware status register and reconfigures the MAC to match. Because SGMII+ has no 2.5G speed code in the SGMII in-band protocol, the PPE always reports 1000M for a 2.5G link. If the loop manages our port, it forces the MAC to 1G, breaking the 2.5G data path. The module excludes our port from the loop's port bitmap so the loop continues managing the other ports while skipping the selected SGMII+ port.

### Why a kernel module

The SGMII+ mode set requires kernel-level operations that can't be done from userspace. The clock tree changes (`clk_set_rate()` and `clk_set_parent()`) to switch from 125 MHz (1G) to 312.5 MHz (2.5G), the uniphy calibration that polls for a hardware calibration bit after the PLL relock, and updating SSDK internal state all require calling into the kernel directly. Raw register writes via `devmem` aren't sufficient.

## What the modules do

Both modules (uniphy1 for eth6, uniphy2 for eth5) follow the same sequence:

1. Takes RTNL, stops MAC sync and pauses initialized MIB work, then takes the target PHY lock and the SSDK config mutex. Only then snapshots the target port's interface mode, uniphy mac_mode and forced-speed state. RTNL and the PHY lock exclude both stock `config_aneg` call paths in default mode as well as hold mode.
2. In hold mode, installs the target-port `config_aneg` guard after checking the snapshot. Saves the target port's current bitmap membership via `qca_ssdk_port_bmp_get()` and clears only its bit via `qca_ssdk_port_bmp_set()`, so the polling loop will skip that port.
3. Takes the target MACs down and clears forced-speed state before calling `adpt_hppe_uniphy_mode_set(0, uniphy_index, 0x0c)`. This selects SGMII+ (uniphy register 0x218: 0x50 rather than SGMII 0x30), runs the PLL reset/calibration sequence and sets TX/RX clocks to 312.5 MHz.
4. Updates per-port interface mode and per-uniphy mac_mode bookkeeping, then runs the vendor MAC link-up sequence for 2500 full duplex.
5. Updates the target port's SFP speed, duplex and link caches to 2500/full/up under the config mutex. A peer-port stock path may requeue MAC sync; that worker serializes on the same mutex and skips the excluded target bit. Releases the config and PHY locks, resumes MIB work and MAC sync, then releases RTNL. There is no one-second stabilization sleep in the module; the loader's clock and link waits are separate.
6. After workers resume, sends `ssdk_port_link_notify` and `ubnt_send_phy_event` when available, and schedules an asynchronous `RTM_NEWLINK` notification after two seconds so `ubios-udapi-server` re-reads ethtool.
7. On unload, enters the same locked transition. It restores the saved hardware mode only if the current interface/mac_mode pair is still SGMII+ (`6` / `0x0c`); if stock has made a newer decision or the mode cannot be read, it preserves the current hardware settings. It restores the saved speed/duplex caches and only its own bitmap bit, resets the port polling status and resumes workers. Other ports' bitmap changes are preserved. If it cannot enter the transition, it logs that restoration was not performed and a planned reboot is required. Routine updates and rollback use a planned gateway reboot; see below.

The mode set causes the target interface to flap briefly (~300ms) while the PLL relocks.

### Module modes

Both port-specific module names are retained and share one implementation to keep
behavior consistent. Both sources declare `MODULE_VERSION("5")`; the vendor
`CONFIG_MODULE_STRIPPED` setting can remove this metadata from the built module.
The `hold` parameter is set at load time and is read-only afterward:

| Mode | Module behavior | Loader behavior |
|---|---|---|
| `hold=0` (default) | Sets up 2.5G, leaves the QCA SFP callback unchanged; stock SFP recovery can change the port afterward | Existing boot-time clock verification and retry path; no EEPROM identity polling or persistent watcher |
| `hold=1` (opt-in, Testing) | Wraps the QCA SFP `config_aneg` callback for the selected port so SFP events cannot undo SGMII+; exposes `pcs_link` | Checks the loaded mode and PCS capability, then monitors SFP identity and the real SerDes link with bounded recovery |

Without an opt-in flag, the loader does not add a `hold` argument or require a new
instance lock; existing older modules remain usable through the default path.
The QCA SFP callback stays unchanged in this mode, so an SFP reboot, replug or
fiber return can revert the SerDes to 1G. This is not a verified working 1G
fallback: the port remains excluded from polling and its speed cache is still
2500. A link may have no working data path until a planned gateway reboot, and
there is no watcher to repair it. Choose hold mode only if you need to suppress
these changes and accept its current testing status.

With `hold=1`, the module ignores `config_aneg` only for its own SSDK port while
loaded (`suppressed` counts ignored calls). Calls for the other port are passed
through. It installs the wrapper only if the callback still points at the expected
QCA SFP function and removes its wrapper during cleanup. Because both cages share
that driver callback, **at most one port may use hold mode at a time**. A second
hold request is rejected before changing the hardware; that port gets no module,
not an automatic default-mode instance. To use the other port in default mode,
configure only the first port for hold. This combination is supported by the
design, not yet dual-port hardware acceptance.

Both modules take RTNL, stop MAC sync, pause active MIB work, then take the target
PHY lock and qca-ssdk's config mutex before taking the mode snapshot. RTNL and the
PHY lock exclude both stock `config_aneg` call paths in default mode too; this
protection does not depend on installing the hold guard. The target MACs are taken
down before switching the uniphy, followed by the vendor link-up sequence for
2500 full duplex. Failures unwind acquired state without blindly
switching hardware. These changes do not make every external statistics reader
(for example `ethtool -S`) use the same lock.

A previous live unload/reload under WAN traffic was followed by a SoC reset
(`AHB Timeout`); its cause was not proven. Replacing a module file does not replace
the running code, and older loaded versions lack the new locking. Install, update
or roll back using a **planned gateway reboot**, rather than manual live
unload/reload. Historical v4/v5.1 hardware results do not establish acceptance of
the new default/hold combinations on either port.

### Port-to-module mapping

| Module | Uniphy | SSDK port | Interface | Physical label | Boot script |
|---|---|---|---|---|---|
| `force_uniphy1_sgmiiplus` | 1 | 5 | eth6 | Port 7 (SFP+) | `20-sfp-sgmiiplus.sh` |
| `force_uniphy2_sgmiiplus` | 2 | 6 | eth5 | Port 6 (SFP+) | `19-sfp-sgmiiplus-eth5.sh` |

Each module owns one port and restores only its own bitmap bit. The shared QCA SFP callback limits **hold mode** to one port; it does not impose a blanket ban on loading both modules. Concurrent operation and transitions on both ports still need hardware validation.

## SFP compatibility

The module changes only the gateway side of the link. The SFP must switch its own host-side SerDes to 2.5G SGMII+ / HSGMII to match. If it stays at 1G, the gateway reports 2.5G but no traffic passes, or the port reverts to 1G.

| SFP | Status | Notes |
|---|---|---|
| Calix 100-05609 | Works | |
| LuLeey LL-XS2510 | Works | |
| Zyxel PMG3000-D20B | Works on firmware V2.50+ | Older firmware has SFP PHY issues that the V2.50 lineage fixes |
| ODI DFP-34X-2C2 / DFP-34X-2CY3 | Not supported | Auto-sensing cannot switch between SGMII and HiSGMII ([Hack GPON known bug](https://hack-gpon.org/ont-odi-realtek-dfp-34x-2c2/)). A stored HiSGMII `LAN_SDS_MODE` did not take effect at runtime on V1.7.1-231022 ([#3](https://github.com/Ozark-Connect/unifi-perf-tweaks/issues/3)) |

## Important caveats

### Port bitmap exclusion

Each module removes its target port from the SSDK's polling loop port bitmap. This is a runtime-only change to a value in kernel memory - it persists as long as the module is loaded and is restored on unload. The polling loop continues managing all other ports for link state, speed/duplex sync, and flow control.

The bitmap exclusion is necessary because the loop reads link speed from a PPE hardware register that always reports 1000M for SGMII+ links (the SGMII in-band protocol has no 2.5G speed code). If the loop managed the port, it would force the MAC to 1G on every link-up event, creating a MAC/SerDes speed mismatch that kills the data path.

Default port bitmap is `0x62` (ports 1, 5, 6). The uniphy1 module clears bit 5 (port 5 / eth6), the uniphy2 module clears bit 6 (port 6 / eth5). Each module restores only its own bit, preserving the other port's membership. Only hold mode has the shared-hook restriction described above; do not load two hold instances.

### SSDK bookkeeping

Each module also writes to two SSDK internal data structures (per-port interface mode and per-uniphy mac_mode). These are the same structures the SSDK itself writes during normal port initialization - the module sets them to SGMII+ values so any SSDK code path that checks the port mode sees a consistent state.

### Version history

v1 stopped the MAC sync polling loop entirely. This caused forwarding drops on eth5 and flow control loss during UniFi Network config pushes (IDS/IPS toggle, etc.), because the loop manages link state for all ports. v2 updated bookkeeping and restarted the loop, but the loop's link-up speed sync (reading 1000M from PPE) broke the 2.5G data path on cold starts (SFP reboot, gateway reboot, DSMP restart). v3 excludes port 5/eth6 from the bitmap, keeping the loop running for all other ports while preventing it from touching our SGMII+ port. v4 adds speed reporting: writes 2500 to the SSDK SFP PHY speed cache so ethtool/sysfs/UDAPI/UniFi Network all report 2.5G instead of the misleading 1000M. v5 uses a common implementation for both ports and switches under qca-ssdk's config mutex. The optional `hold=1` mode keeps SGMII+ across SFP events; `hold=0` preserves stock SFP recovery. If you are running v1, v2, or v3, upgrade.

### Symbol resolution

The module resolves these symbols from `qca-ssdk.ko` at load time. Their addresses change across UniFi OS versions even though the kernel stays the same - Ubiquiti ships a different `qca-ssdk.ko` build with each release:

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

The common v5 implementation uses the following additional symbols for guarded transitions and optional hold mode, resolving the required symbols by name rather than guessing addresses: `adpt_hppe_port_interface_mode_get`, `ssdk_dt_global_get_mac_mode`, `hsl_port_phydev_get`, `qca_ssdk_phydev_to_port`, `hppe_uniphy_channel0_input_output_6_get`, `qca_mac_port_status_init`, `sfp_phy_config_aneg`, `hsl_port_feature_get/set/clear`, `hppe_uniphy_channel0_force_speed_mode_set`, `adpt_hppe_port_txmac_status_set`, `adpt_hppe_port_rxmac_status_set`, `adpt_hppe_port_bridge_txmac_set`, `adpt_hppe_gcc_uniphy_clock_status_set`, `adpt_hppe_gcc_port_speed_clock_set`, `adpt_hppe_port_mac_speed_set`, `adpt_hppe_port_mac_duplex_set`, `adpt_hppe_uniphy_port_adapter_reset`, `qca_phy_mib_work_pause/resume`. It also relies on private qca-ssdk offsets (config mutex at `priv+0x990`, sync work at `priv+0x9b0`, MIB work at `priv+0x2a0`) and checks the work functions at those offsets (`qca_mac_sw_sync_work_task`, `qca_phy_mib_work_task`) before taking over; on a mismatch it does not load.

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
| 6.0.10 | 5.4.213-ui-ipq9574 (rebuilt) | `ffffffc008934488` ³ |

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

³ UXG-Fiber, live. All ten addresses are identical to the 6.0.5 table above. See [compat-6.0.10.md](compat-6.0.10.md).

The module resolves local symbols at runtime via `kallsyms_lookup_name()`. The historical tables above describe earlier tested modules; they do not qualify the new default/hold modes on every listed OS version. Exported symbols (`ssdk_mac_sw_sync_work_stop`, `ssdk_mac_sw_sync_work_start`) are resolved by the kernel's normal module linker. If a required symbol lookup fails, the module refuses to load rather than guessing an address. Optional external notification symbols are used only when available.

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

The boot scripts run from `/data/on_boot.d/`, which requires udm-boot to be installed on your gateway. Install it before deploying the modules so they load during boot. See [prerequisites.md](prerequisites.md) for instructions.

The examples below show deployment for eth6 (Port 7). For eth5 (Port 6), substitute:
- Module: `force_uniphy2_sgmiiplus.ko` instead of `force_uniphy1_sgmiiplus.ko`
- Boot script: `19-sfp-sgmiiplus-eth5.sh` instead of `20-sfp-sgmiiplus.sh`
- Log file: `/var/log/sfp-sgmiiplus-eth5.log` instead of `/var/log/sfp-sgmiiplus.log`
- Clock path: `uniphy2_gcc_tx_clk` instead of `uniphy1_gcc_tx_clk`

Both modules deploy to the same directory (`/data/sfp-sgmiiplus/`). Hold mode may be enabled for only one port; see [module modes](#module-modes).

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

### 3. Choose the mode

No flag is needed for the default setup. To opt one port into hold mode, create
its flag before the planned reboot:

```bash
# On the gateway, choose ONE port:
touch /data/sfp-sgmiiplus/hold-eth6   # eth6 / Port 7
# OR: touch /data/sfp-sgmiiplus/hold-eth5   # eth5 / Port 6
```

`/data/sfp-sgmiiplus/hold` is a global alternative for a single-port deployment.
With both loaders installed, that global flag requests hold on both. Which
loader claims the shared hook first is not deterministic; the other request is
rejected and leaves that port without a module, rather than falling back to
default mode. Use a port-specific flag instead. Flags select hold by their
presence, not their contents. Change flags for the next planned gateway boot;
recovery reruns retain the mode selected at startup. Flag edits do not change a
running module or watcher.

### 4. Verify copied files, then reboot

Compare the module and loader checksums locally and on the gateway before the
reboot. Use the matching module and script paths from the mapping above:

```bash
# Local files:
sha256sum modules/force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.ko scripts/20-sfp-sgmiiplus.sh
# Copied files on the gateway:
ssh root@<gateway-ip> 'sha256sum /data/sfp-sgmiiplus/force_uniphy1_sgmiiplus.ko /data/on_boot.d/20-sfp-sgmiiplus.sh'
```

Schedule a gateway reboot through the UniFi console. Do not run the loader
manually to replace a currently loaded module. After the gateway returns, check:

```bash
ssh root@<gateway-ip> 'lsmod | grep force_uniphy1'
ssh root@<gateway-ip> cat /var/log/sfp-sgmiiplus.log
ssh root@<gateway-ip> cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
# Expected clock after successful setup: 312500000
```

For hold mode, also verify the effective mode and the real SerDes link:

```bash
# On the gateway; substitute force_uniphy2_sgmiiplus for eth5:
P=/sys/module/force_uniphy1_sgmiiplus/parameters
cat "$P/hold"       # Y or 1
cat "$P/pcs_link"   # 1 when the host SerDes is linked
```

The loader checks these capabilities after loading. If an old module does not
accept or expose hold mode, the loader exits with status 1 and requests a planned
gateway reboot with a matching module, rather than treating this as a transient
clock failure and retrying. A legacy module that did load is left loaded; the
capability failure does not trigger an unsafe live unload. Hold capability is not
inferred by searching strings in the `.ko`. Older modules are supported without a
hold flag.

### Updating

Replace the appropriate `.ko` and boot script using steps 1 and 2, compare their
checksums as above, and reboot the gateway during a planned outage. The running
module remains unchanged until the reboot. Do not use live `rmmod` / `insmod` to
apply the new file: an old module's unload path may lack the current locking.
Check the loaded mode, clock, link and loader log after the reboot.

### ethtool / UniFi Network speed reporting

Each module updates ethtool, sysfs, UDAPI, and the UniFi Network dashboard to report 2.5G for its target interface. This works around a cosmetic limitation of SGMII in-band signaling - the protocol has no speed code for 2.5G, so the PPE hardware always reports 1000M for SGMII+ links.

The fix writes to the SSDK's per-port SFP PHY speed cache (the same cache that the "QCA SFP" fake PHY driver's `sfp_read_status()` copies into `phydev->speed`) before resuming workers. After resume it schedules a transient `RTM_NEWLINK` event (interface alias set/clear) with a two-second delay, allowing the PHY state machine to copy the cached value before `ubios-udapi-server` re-reads ethtool. This is a reporting mechanism, not proof that traffic passes.

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

After the planned gateway reboot and boot-time module load:

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

### Boot-time retry

The boot-time mode set does not always commit. `insmod` can succeed and the module
can log `uniphy1 set to SGMII+ 2.5G` while the uniphy clock stays at 125 MHz and the
port sits at NO-CARRIER against an SFP that has already switched to 2.5G. A set that
*does* commit can still be reverted up to ~35s later when it happens early in boot.
Which boots are affected is timing-dependent, so the same firmware and SFP can boot
cleanly and fail on the next try.

The scripts handle this themselves. After each `insmod` they require the clock to read
312500000 Hz *and hold it for 45s* — a single read one second after load only proves a
momentary state. On a mismatch the script `rmmod`s to restore stock SGMII 1G, waits up
to 30s for the stock 1G link to recover, backs off, and retries; 5 attempts total.

The default path judges success on the clock rather than carrier, so an SFP that
cannot first establish a stock 1G link can still be configured for 2.5G. Hold mode
also requires the SerDes link, as described below, on either port.

If all five clock attempts fail, the loader removes the module, attempts to restore
stock SGMII 1G, logs an ERROR and exits non-zero. A working data path still depends
on the SFP and must be verified; a 1G clock or carrier alone does not prove traffic
recovery. The following is an example of the bounded retry log:

```
WARNING: Attempt 1 expected 312500000 Hz, got 125000000 Hz
Removing force_uniphy1_sgmiiplus to restore stock SGMII 1G before retry
eth6 stock 1G carrier recovered after 2s
Retrying after 5s backoff
Loading force_uniphy1_sgmiiplus (attempt 2/5)...
Clock rate after attempt 2: 312500000 Hz
Clock reached 312500000 Hz; verifying it holds for 45s
Verified: uniphy1 running at 312.5 MHz (SGMII+ 2.5G) and held for 45s
```

The retry is deliberately bounded: if something on the host actively re-asserts 1G, an
unbounded loop would flap the WAN forever. Worst case the loop runs ~7 minutes after the
initial carrier wait, bouncing the port up to five times. It runs in the background, so
`on_boot.d` is never blocked.

### Optional hold monitoring (both ports)

With a hold flag, the matching loader passes `hold=1` and checks the effective
`hold` parameter (`Y` or `1`) and readable `pcs_link` after load. It does not require
a particular binary string or module version marker. The `hold` parameter cannot
be toggled at runtime; choose the mode for the next planned boot. Recovery
re-execs retain the selected mode instead of applying later flag changes.

In hold mode, each loader:

- waits for a nonempty cage and rechecks the SFP identity (A0h bytes 20-83) before
  loading;
- requires the clock to hold for 45s and the SerDes link to come up within 180s;
  on failure it falls back to stock 1G and can remember a stick that only links at
  1G until the next gateway boot;
- watches SFP identity and PCS link without resetting an already working 2.5G link
  merely because the identity changed;
- starts recovery after 180s without PCS link, with a monotonic 360s hard limit
  since the last observed link so unstable identities cannot postpone recovery;
- admits at most three automatic recovery runs per rolling hour, using monotonic
  uptime. The initial boot run does not count; each run has at most five load
  attempts. When the budget is full, the module stays off until an entry expires;
- requires a writable instance lock and `flock`, held across re-exec, plus a
  readable clock path. A missing prerequisite stops hold setup; losing the clock
  path during verification is not counted as success.

With no flag, none of this EEPROM polling or persistent watching runs, and the
loader retains its existing default clock retry path without an extra `flock`
requirement. An SFP event may therefore revert the SerDes to 1G while the port is
still excluded from polling and the speed cache stays at 2500. Working 1G traffic
is not established by that reversion; the data path may remain unavailable until
a planned gateway reboot.

The shared QCA SFP callback permits only one active hold instance. Test the
other-port default combination separately; common source code and own-bit bitmap
restoration do not by themselves prove dual-port behavior on hardware.

### Validation scope

Hardware acceptance of the new mode split is pending: boot and SFP-event recovery
on both ports, default mode alongside one hold port, planned-reboot rollback and
24-hour operation. The earlier v5.1 results and historical OS tables are not a
substitute for these checks. Build hashes and test results must come from the
final artifacts; none are claimed here in advance.

Host regression tests require Python 3, a C compiler, a POSIX shell and Git with
baseline object `7775899` available for the actual legacy comparison; a missing
baseline fails the tests explicitly rather than skipping the comparison:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/sfp-sgmiiplus -p 'test_*.py'
```

The loader runs with isolated hardware stubs, including real re-execs and FD locks.
The C tests compile the actual module source against a fake SSDK and check snapshot
ordering, failed-takeover cleanup, rollback and the callback barrier protocol. These
checks do not validate the vendor ABI, ARM memory-model outcomes or live switching;
those still need the pinned kernel build and separate hardware acceptance.

## Reverting

Use a planned gateway reboot for rollback. Do not unload a running module just to
replace its file; an older version may switch hardware without the new locking.

### Return to stock SGMII 1G

On the gateway, move the boot script for the port you want to revert out of
`on_boot.d`, keeping a fallback copy. Changing its extension alone is insufficient
for boot services that execute every executable file:

```bash
# eth6 / Port 7:
mv /data/on_boot.d/20-sfp-sgmiiplus.sh /data/sfp-sgmiiplus/20-sfp-sgmiiplus.sh.disabled
# eth5 / Port 6, if reverting that port too:
# mv /data/on_boot.d/19-sfp-sgmiiplus-eth5.sh /data/sfp-sgmiiplus/19-sfp-sgmiiplus-eth5.sh.disabled
```

Reboot the gateway through the UniFi console during a planned outage. After boot,
verify that the disabled port's module is absent and its clock is back at stock:

```bash
lsmod | grep force_uniphy
cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate   # eth6
cat /sys/kernel/debug/clk/uniphy2_gcc_tx_clk/clk_rate   # eth5
# Reverted port: expected 125000000
```

Only check a port you reverted; another enabled module may still be running at
2.5G. Keep module files and disabled scripts until rollback has been verified.

### Turn off hold mode but retain boot-time 2.5G

Remove the hold flag for the selected port and the global flag, if present. For
example, for eth6:

```bash
rm -f /data/sfp-sgmiiplus/hold-eth6 /data/sfp-sgmiiplus/hold
```

Leave the loader enabled and reboot during a planned outage. With the new module,
`parameters/hold` should then report `N` or `0`. Removing a flag does not stop a
running hold instance. For an earlier module without this parameter, check the
clock and the default-path loader log instead.

### Restore an earlier module

Copy your saved known-working `.ko` and matching loader back to their paths,
verify the copied checksums, and reboot. Remove any hold flag for that port (and
the global flag) before booting a module that does not support hold. Verify the
clock, traffic and loader log afterward. Keep the fallback files until this check
has passed.

## Cross-compiling

The UCG-Fiber / UXG-Fiber has `make` but no gcc and no kernel headers, so the modules have to be cross-compiled on another machine.

### Requirements

You need `aarch64-linux-gnu-gcc` (or any ARM64 cross-compiler) and a kernel source tree matching `5.4.213-ui-ipq9574` with a matching `.config`.

Ubiquiti does not publicly distribute kernel source. Your options are to extract `/proc/config.gz` from the gateway (if available) and build a matching 5.4 source tree, or use a Docker-based cross-compilation environment with the extracted config.

### Build

The shared build script [`modules/sfp-sgmiiplus/build.sh`](../modules/sfp-sgmiiplus/build.sh) builds both port-specific `.ko` files by default in a pinned Debian image against a pinned QSDK kernel commit and checks the vermagic. The port-specific `build.sh` wrappers build only their respective module. The compiler comes from the current Debian packages and is only checked against the vendor version. Usage is in the shared script header. Manual build:

```bash
# eth6 / Port 7:
cd modules/force-uniphy1-sgmiiplus/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source

# eth5 / Port 6:
cd modules/force-uniphy2-sgmiiplus/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source
```

Since the modules resolve local symbols via `kallsyms_lookup_name()` at runtime, a rebuilt module should work across OS versions without address changes. After a firmware update, verify the modules still load and resolve correctly via `dmesg`, then check the selected mode, clock, link and traffic. A successful build or host regression test is not hardware acceptance of either mode or a dual-port combination.
