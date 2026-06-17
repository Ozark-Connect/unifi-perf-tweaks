# UniFi OS 5.1.19 Compatibility Verification

Verified 2026-06-17 on a test UCG-Fiber running UniFi OS 5.1.19.

**Scope:** This round verified the **SGMII+ kernel module** against the upgraded firmware. The boot scripts (05/06/07/10/15) were not re-checked live this round; they are expected compatible (kernel and userland unchanged from 5.1.15) but carry the 5.1.15 sign-off, not a fresh 5.1.19 one.

## Kernel & vermagic

- `uname -r` = `5.4.213-ui-ipq9574` — **unchanged** from 5.0.10 / 5.1.12 / 5.1.15.
- The repo `.ko` modules are built against this exact kernel, so vermagic matches and the module will `insmod` without a rebuild.

## qca-ssdk Binary Analysis

Pulled `qca-ssdk.ko` from the 5.1.19 gateway (`/lib/modules/5.4.213-ui-ipq9574/extra/qca-ssdk.ko`) and compared against the known-good 5.1.12 / 5.1.15 references on a local build host (`aarch64-linux-gnu-objdump`, binutils 2.44). Per SOP, all RE was done on pulled copies — nothing was run on the gateway.

| Version | File Size  | md5sum                             |
|---------|-----------|-------------------------------------|
| 5.1.12  | 3,456,424 | 8cdd37ab007a26982898eb5737ba5a46    |
| 5.1.15  | 3,456,424 | 8b6799b7c4ada78c389b8b8381ad6b4a    |
| 5.1.19  | 3,456,424 | dd7911587eae837dcf0ffef30fa5be62    |

**5.1.19 is code-identical to 5.1.12 and 5.1.15.** `.text` section raw bytes (`objdump -s -j .text`) compare **byte-identical** to 5.1.15; full `.text` disassembly diff against both 5.1.12 and 5.1.15 = zero instruction changes (only the embedded filename in the objdump header differs). Different md5sums come from non-code ELF metadata only.

Verified specifically against the symbols/offsets the SGMII+ module depends on:

- **All 10 required symbols present at byte-identical addresses and linkage** (5.1.15 → 5.1.19):

  | Symbol | Addr | Type |
  |---|---|---|
  | `adpt_hppe_uniphy_mode_set` | `0x38200` | T |
  | `_adpt_hppe_port_interface_mode_set` | `0x234a8` | t |
  | `ssdk_dt_global_set_mac_mode` | `0xe107c` | T |
  | `qca_ssdk_port_bmp_get` | `0x75458` | T |
  | `qca_ssdk_port_bmp_set` | `0x75438` | T |
  | `ssdk_phy_priv_data_get` | `0xe5978` | T |
  | `ssdk_port_link_notify` | `0xb1ec4` | T |
  | `ubnt_send_phy_event` | `0x24068` | t |
  | `ssdk_mac_sw_sync_work_stop` | `0xe59b0` | T |
  | `ssdk_mac_sw_sync_work_start` | `0xe5a0c` | T |

- `ssdk_phy_priv_data_get` disassembly — byte-identical.
- Speed cache offset `0x690` / duplex cache offset `0x6d0` — 1 reference each, same as 5.1.15.

## SGMII+ Module Live Test

Test-loaded `force_uniphy1_sgmiiplus.ko` (vermagic `5.4.213-ui-ipq9574`, matches) on the empty/down eth6 port. NetworkOptimizer gates module load on link presence, so it would skip an empty port — a manual `insmod` is the correct way to exercise the module here. The register writes execute independent of SFP presence, so an empty port is a valid load/unload test.

Load (`insmod rc=0`):

```
force_sgmiiplus: resolved all symbols
force_sgmiiplus: port bitmap 0x62 -> 0x42 (port 5 excluded)
force_sgmiiplus: uniphy1 set to SGMII+ 2.5G
force_sgmiiplus: loop restarted (port 5 excluded)
force_sgmiiplus: speed cache 65535 -> 2500
force_sgmiiplus: speed reporting updated
```

All kallsyms lookups resolved on 5.1.19, and the `65535 -> 2500` speed-cache write confirms the `0x690` offset still lands correctly (65535 = 0xFFFF = no-SFP). Clean unload (`rmmod rc=0`):

```
force_sgmiiplus: speed cache restored to 65535
force_sgmiiplus: reverted, loop restarted with full bitmap 0x62
```

**The live eth5 10G DAC trunk stayed up (carrier=1, 10000) through load and unload** — the port-5 bitmap exclusion works as designed.

### Residual after no-reboot test

The unload reverts uniphy1 to SGMII 1G, leaving `uniphy1_gcc_tx_clk` at `125000000` vs the fresh-boot idle `312500000` (uniphy0/uniphy2 still idle at 312.5M). On the empty/down eth6 port this has no functional effect; a reboot or an eth6 link event restores exact parity. This is expected behavior of a no-reboot load/unload cycle, not a compatibility issue.

### Note: `clk_rate` is not a mode discriminator on 5.1.19

On 5.1.19, all six uniphy GCC clocks idle at the same rate with no link/module loaded:

```
uniphy0_gcc_tx/rx_clk = 312500000
uniphy1_gcc_tx/rx_clk = 312500000
uniphy2_gcc_tx/rx_clk = 312500000
```

This is the idle GCC parent rate, **not** an indication that any uniphy is in SGMII+ mode. The module header's documented verification step — "clk_rate should show 312500000 after load, 125000000 after unload" — does **not** discriminate mode on 5.1.19. Verify a live load via the `dmesg` pr_info sequence (`resolved all symbols` → `port bitmap 0x62 -> 0x42` → `uniphy1 set to SGMII+ 2.5G` → `speed cache ... -> 2500`) instead of the clock rate.

## Conclusion

The SGMII+ kernel module is **compatible with UniFi OS 5.1.19**, confirmed both statically (kernel unchanged, `qca-ssdk.ko` code-identical to verified 5.1.12 / 5.1.15, all symbols + struct offsets intact) and via a live load/unload test (clean load, all symbols resolved, correct revert, live eth5 trunk undisturbed). No rebuild required.
