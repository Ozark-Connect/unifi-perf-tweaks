/*
 * force_uniphy1_sgmiiplus.c — Force UXG-Fiber uniphy1 (eth6) to SGMII+ 2.5G
 *
 * Bypasses the SSDK's SFP EEPROM validation by calling the uniphy mode set
 * function directly, skipping the port speed set path that gates on
 * sfp_phy_read_abilities.
 *
 * Target: UXG-Fiber, IPQ9574, kernel 5.4.213-ui-ipq9574
 * Module: qca-ssdk.ko must be loaded
 *
 * WARNING: Hardcoded kallsyms addresses are firmware-version-specific.
 *          Update addresses if Ubiquiti pushes a firmware update.
 *
 * BUILD:   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
 * LOAD:    insmod force_uniphy1_sgmiiplus.ko
 * UNLOAD:  rmmod force_uniphy1_sgmiiplus  (reverts to SGMII 1G)
 * VERIFY:  cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
 *          (should show 312500000 after load, 125000000 after unload)
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Yelcot GPON Bypass Project");
MODULE_DESCRIPTION("Force UXG-Fiber uniphy1 to SGMII+ 2.5G");

/*
 * From /proc/kallsyms on firmware 5.4.213-ui-ipq9574:
 *
 *   ffffffc0089e2ab0 T ssdk_mac_sw_sync_work_stop    [qca_ssdk]
 *   ffffffc0089e2b0c T ssdk_mac_sw_sync_work_start   [qca_ssdk]
 *   ffffffc008935300 t adpt_hppe_uniphy_mode_set      [qca_ssdk]
 *
 * The _stop/_start are exported (T), so we can use symbol lookup.
 * adpt_hppe_uniphy_mode_set is local (t), so we hardcode or kallsyms_lookup_name.
 */

/* Exported by qca-ssdk.ko */
/* Ghidra decompiles as void but x0 passes through to ssdk_phy_priv_data_get(dev_id) */
extern int ssdk_mac_sw_sync_work_stop(unsigned int dev_id);
extern int ssdk_mac_sw_sync_work_start(unsigned int dev_id);

/*
 * adpt_hppe_uniphy_mode_set(uint dev_id, uint uniphy_index, int mode)
 *
 * Mode 0x0c = SGMII+ (2.5G)
 * Mode 0x0f = SGMII channel 0 (1G, the default for SFP ports)
 *
 * Not exported — resolve via kallsyms or hardcode.
 */
typedef int (*uniphy_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, int mode);

static uniphy_mode_set_fn uniphy_mode_set;

/* Hardcoded fallback — update on firmware change */
#define UNIPHY_MODE_SET_ADDR 0xffffffc008935300UL

#define SSDK_UNIPHY_SGMIIPLUS 0x0c
#define SSDK_UNIPHY_SGMII_CH0 0x0f
#define UNIPHY_INDEX 1  /* uniphy1 = eth6 = SFP+ port */
#define DEV_ID 0

static bool polling_stopped;

static int __init force_sgmiiplus_init(void)
{
	int ret;

	/* Try kallsyms first, fall back to hardcoded address */
	uniphy_mode_set = (uniphy_mode_set_fn)kallsyms_lookup_name(
		"adpt_hppe_uniphy_mode_set");
	if (!uniphy_mode_set) {
		pr_warn("force_sgmiiplus: kallsyms_lookup_name failed, using hardcoded address\n");
		uniphy_mode_set = (uniphy_mode_set_fn)UNIPHY_MODE_SET_ADDR;
	} else {
		pr_info("force_sgmiiplus: resolved adpt_hppe_uniphy_mode_set via kallsyms\n");
	}

	/*
	 * Step 1: Stop the MAC sync polling loop.
	 *
	 * The polling task (qca_hppe_mac_sw_sync_task) runs every ~12s,
	 * reads the SFP EEPROM, and forces SGMII mode. If we don't stop
	 * it, it will revert our SGMII+ change within seconds.
	 */
	ret = ssdk_mac_sw_sync_work_stop(DEV_ID);
	if (ret < 0 && ret != -0x13) {
		pr_err("force_sgmiiplus: ssdk_mac_sw_sync_work_stop failed: %d\n", ret);
		return ret;
	}
	polling_stopped = true;
	pr_info("force_sgmiiplus: MAC sync polling stopped\n");

	/*
	 * Step 2: Set uniphy1 to SGMII+ mode (0x0c).
	 *
	 * This calls the same code path the SSDK uses internally:
	 * - Sets uniphy reg 0x218 = 0x50 (SGMII+ SerDes select)
	 * - PLL reset/relock (reg 0x780: 0x2bf -> 0x2ff, 200ms total)
	 * - Mode control reg 0x46c updated with SGMII+ flags
	 * - Software reset + calibration
	 * - Clock set to 312.5 MHz (2.5G)
	 *
	 * eth6 will flap during this (~300ms). VLAN 4094 (DSMP) drops
	 * briefly but the SFP re-negotiates automatically.
	 */
	pr_info("force_sgmiiplus: setting uniphy%d to SGMII+ (mode 0x%x)...\n",
		UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);

	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);
	if (ret != 0) {
		pr_err("force_sgmiiplus: uniphy_mode_set failed: %d\n", ret);
		/* Try to restart polling so we don't leave the system in a bad state */
		ssdk_mac_sw_sync_work_start(DEV_ID);
		polling_stopped = false;
		return ret;
	}

	pr_info("force_sgmiiplus: uniphy%d set to SGMII+ 2.5G successfully\n", UNIPHY_INDEX);
	pr_info("force_sgmiiplus: verify: cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate\n");

	return 0;
}

static void __exit force_sgmiiplus_exit(void)
{
	int ret;

	if (!uniphy_mode_set)
		return;

	/*
	 * Revert to SGMII 1G (mode 0x0f) and restart polling.
	 * This restores the default state — link drops to 1G.
	 */
	pr_info("force_sgmiiplus: reverting uniphy%d to SGMII 1G...\n", UNIPHY_INDEX);

	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMII_CH0);
	if (ret != 0)
		pr_err("force_sgmiiplus: revert to SGMII failed: %d\n", ret);

	if (polling_stopped) {
		ssdk_mac_sw_sync_work_start(DEV_ID);
		pr_info("force_sgmiiplus: MAC sync polling restarted\n");
	}

	pr_info("force_sgmiiplus: unloaded, uniphy%d back to SGMII 1G\n", UNIPHY_INDEX);
}

module_init(force_sgmiiplus_init);
module_exit(force_sgmiiplus_exit);
