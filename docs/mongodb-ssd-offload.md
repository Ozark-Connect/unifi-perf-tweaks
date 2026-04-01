# mongodb-ssd-offload

**Script:** [`scripts/20-mongodb-ssd-offload.sh`](../scripts/20-mongodb-ssd-offload.sh)
**Compatibility:** UCG models with NVMe SSD - UCG-Fiber, UCG-Max, or any model with `/volume1`
**Risk level:** Medium - moves database I/O to a different device. Has graceful fallback to eMMC.

## Problem

MongoDB runs on eMMC by default. The UniFi controller periodically bulk-deletes traffic flow audit records (~15,000 docs every 2-3 hours), generating 45,000+ index key deletions in a single operation. This hammers the eMMC flash controller, triggering garbage collection stalls that last 30+ minutes.

On models with CPU-attached network ports (UCG-Fiber's SFP+ ports, etc.), these eMMC GC stalls directly cause cyclical packet loss.

### Why the SSD Isn't Used by Default

UCG models with NVMe SSDs reserve them exclusively for Protect video recordings. Ubiquiti hardcoded all management plane I/O to eMMC. The SSD sits idle while MongoDB does database workloads on flash storage designed for boot firmware.

### eMMC Health Context

This isn't about eMMC wear - the flash cells are fine. eMMC GC stalls are inherent to how flash controllers manage write pressure. Even a healthy eMMC will stall under sustained writes. The fix is to move the writes to NVMe, which has proper I/O scheduling and write buffering.

## What the Script Does

1. Waits up to 60 seconds for `/volume1` (SSD) to mount at boot
2. If no SSD copy exists: stops UniFi, copies eMMC data to SSD, sets up bind mount
3. If SSD copy exists: sets up bind mount directly
4. Starts UniFi controller on the SSD-backed MongoDB

### Graceful Fallback

If `/volume1` never mounts (SSD missing, failed, or different model), the script logs a warning and exits. The controller runs on eMMC as normal - no harm done.

## Requirements

- NVMe SSD mounted at `/volume1` (standard on UCG-Fiber and UCG-Max)
- Enough free space on SSD for MongoDB data (typically 500MB-2GB depending on site size)
- If Protect is using the SSD, ensure there's headroom - MongoDB data is small relative to video

## First-Run Migration

On first boot with this script, it:
1. Stops the UniFi controller (brief UI downtime)
2. Copies all MongoDB data from eMMC to SSD
3. Sets up the bind mount
4. Starts the controller

Subsequent boots only do step 3-4 (the copy already exists on SSD).

## Verification

```bash
# Check bind mount is active
mountpoint /data/unifi/data/db
# Should say: /data/unifi/data/db is a mount point

# See where it's mounted from
findmnt /data/unifi/data/db
# SOURCE should show your SSD device (e.g., /dev/md3[/unifi-db] on UCG-Fiber)

# Check MongoDB is running on SSD
ls -la /data/unifi/data/db/WiredTiger
# Should exist and be recently modified

# Check SSD data
du -sh /volume1/unifi-db
```

## Firmware Upgrade Safety

- **UniFi Network upgrades:** Safe. The bind mount and SSD data are preserved.
- **UniFi OS upgrades:** The overlay resets, but `/data/on_boot.d/` and `/volume1/unifi-db/` both persist. The boot script re-applies the bind mount on next boot.
- **Factory reset:** May wipe `/volume1`. MongoDB falls back to eMMC. The boot script will re-migrate on next boot.

**Important:** After a firmware upgrade, the controller may have started on eMMC before the boot script ran. If you see stale data, stop the controller, compare timestamps on `WiredTiger` between `/data/unifi/data/db/` and `/volume1/unifi-db/`, and copy the newer one.

## Reverting

**Follow this order exactly. Do not kill mongod or remove the SSD copy until eMMC is confirmed working.**

```bash
# 1. Stop the controller and wait for MongoDB to fully exit
systemctl stop unifi
# Wait until mongod is gone (may take 30-60 seconds)
while pgrep -x mongod >/dev/null; do sleep 1; done

# 2. Unmount the bind mount (exposes original eMMC data underneath)
umount /data/unifi/data/db

# 3. Remove the boot script so it doesn't re-mount on next boot
rm /data/on_boot.d/20-mongodb-ssd-offload.sh

# 4. Start the controller on eMMC
systemctl start unifi

# 5. Verify the controller is running and healthy before cleaning up
systemctl is-active unifi
```

**Do not delete `/volume1/unifi-db/` until you've confirmed the controller is running on eMMC.** That SSD copy is your safety net. If the eMMC data turns out to be stale or corrupted, you can copy it back.

## Results

After moving MongoDB to SSD:
- UI is noticeably faster
- MongoDB operations that were waiting on eMMC I/O complete instantly
- Cyclical packet loss from bulk deletes is eliminated
- eMMC write pressure reduced to near zero (only ubios-udapi-server state writes remain)
