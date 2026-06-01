# UniFi OS 5.1.15 Compatibility Verification

Tested 2026-06-01 on a client UCG-Fiber running UniFi OS 5.1.15.

## Kernel & qca-ssdk Binary Analysis

Pulled `qca-ssdk.ko` from three firmware versions and compared disassembly on a local build host:

| Version | File Size  | Kernel              |
|---------|-----------|---------------------|
| 5.0.10  | 3,457,832 | 5.4.213-ui-ipq9574  |
| 5.1.12  | 3,456,424 | 5.4.213-ui-ipq9574  |
| 5.1.15  | 3,456,424 | 5.4.213-ui-ipq9574  |

**5.1.12 and 5.1.15 are code-identical.** Full `.text` section disassembly diff = zero changes. Different md5sums come from non-code ELF metadata only. 5.0.10 has minor offset shifts (~0x100) but uses the same symbol names and struct layouts.

Verified specifically:
- All 10 kallsyms symbols present at identical offsets across 5.1.12/5.1.15
- `ssdk_phy_priv_data_get` — byte-identical disassembly
- `qca_mac_sw_sync_work_task` — byte-identical disassembly
- Speed cache offset `0x690` / duplex cache offset `0x6d0` — same reference count, same locations

## SGMII+ Module Live Test

Test-loaded `force_uniphy1_sgmiiplus.ko` on the 5.1.15 gateway (no SFP in use):

```
force_sgmiiplus: resolved all symbols
force_sgmiiplus: port bitmap 0x62 -> 0x42 (port 5 excluded)
force_sgmiiplus: uniphy1 set to SGMII+ 2.5G
force_sgmiiplus: loop restarted (port 5 excluded)
force_sgmiiplus: speed cache 65535 -> 2500
force_sgmiiplus: speed reporting updated
```

Clean unload: all state reverted, bitmap restored to `0x62`.

## Boot Script Compatibility

Read-only checks against the running 5.1.15 system:

### 05 - JVM Heap Tuning ✓

- `/etc/default/unifi` present with stock `UNIFI_NATIVE_OPTS` (`-Xms128M -Xmx512M`)
- Suricata/IPS enabled via state file — script would select the 640M locked heap profile
- `unifi-mongodb.service` present (modern firmware unit)

### 06 - MongoDB SSD Offload ✓

- Model: `UCGF` (in supported list)
- SSD mounted at `/volume/<uuid>/` (new-style path, handled by `detect_ssd_mount()`)
- DB on stock eMMC (not bind-mounted) — script would work as fresh deploy
- `WiredTiger.turtle` present in stock location

### 07 - MongoDB SSD Backup ✓

- Same SSD mount and model checks as 06 — all pass

### 10 - Journald Volatile ✓

- Currently stock: `Storage=persistent`, `ForwardToSyslog=yes`
- `syslog-ng conf.d/` present with expected config files including `threat_log.conf`
- Persist file on eMMC (`/var/log/.syslog-ng.persist`) — script would redirect to tmpfs

### 15 - Fan Control Tuning ✓

- `uhwd.service` active
- All four PID categories present: `cpu`, `hdd`, `rtl8372`, `rtl8261`
- Stock setpoints: `cpu=100, hdd=68, rtl8372=109, rtl8261=103, standby=20`
- SDB API responding normally via `SDBClient`

## Conclusion

All scripts and kernel modules are fully compatible with UniFi OS 5.1.15. No path changes, no missing services, no struct/API differences. The kernel and qca-ssdk binary are unchanged from 5.1.12.
