/*
 * force_uniphy1_sgmiiplus.c - Force UCG-Fiber / UXG-Fiber uniphy1 (eth6) to SGMII+ 2.5G
 *
 * Bypasses the SSDK's SFP EEPROM validation by calling the uniphy mode set
 * function directly, then updates the SSDK bookkeeping state so the MAC sync
 * polling loop accepts SGMII+ as the correct mode for this port. The loop
 * continues running and managing link state for all ports (including eth5).
 *
 * Previous versions stopped the polling loop entirely, which caused sporadic
 * forwarding drops on eth5 — the loop handles link-state recovery, MAC
 * speed/duplex sync, and flow control for all ports on the switch.
 *
 * Target: UCG-Fiber / UXG-Fiber, IPQ9574, kernel 5.4.213-ui-ipq9574
 * Module: qca-ssdk.ko must be loaded
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
MODULE_AUTHOR("Ozark Connect");
MODULE_DESCRIPTION("Force UCG-Fiber / UXG-Fiber uniphy1 to SGMII+ 2.5G");

/* Exported by qca-ssdk.ko */
extern int ssdk_mac_sw_sync_work_stop(unsigned int dev_id);
extern int ssdk_mac_sw_sync_work_start(unsigned int dev_id);

typedef int (*uniphy_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, int mode);
typedef int (*port_iface_mode_set_fn)(unsigned int dev_id, unsigned long port_id, int mode);
typedef int (*dt_global_set_mac_mode_fn)(unsigned long dev_id, int uniphy_index, unsigned int mode);

static uniphy_mode_set_fn uniphy_mode_set;
static port_iface_mode_set_fn port_iface_mode_set;
static dt_global_set_mac_mode_fn dt_global_set_mac_mode;

#define SSDK_UNIPHY_SGMIIPLUS 0x0c
#define SSDK_UNIPHY_SGMII_CH0 0x0f
#define UNIPHY_INDEX 1
#define SSDK_PORT_ID 5
#define DEV_ID 0

/* SGMII+ port interface mode (hsl_uniphy_mode_to_port_mode maps 0x0c -> 6) */
#define PORT_MODE_SGMIIPLUS 6

/* Original state — restored on unload */
#define ORIG_PORT_IFACE_MODE 0x0e
#define ORIG_MAC_MODE 0x14

static int __init force_sgmiiplus_init(void)
{
	int ret;

	uniphy_mode_set = (uniphy_mode_set_fn)kallsyms_lookup_name(
		"adpt_hppe_uniphy_mode_set");
	if (!uniphy_mode_set) {
		pr_err("force_sgmiiplus: lookup failed: adpt_hppe_uniphy_mode_set\n");
		return -ENOENT;
	}

	port_iface_mode_set = (port_iface_mode_set_fn)kallsyms_lookup_name(
		"_adpt_hppe_port_interface_mode_set");
	if (!port_iface_mode_set) {
		pr_err("force_sgmiiplus: lookup failed: _adpt_hppe_port_interface_mode_set\n");
		return -ENOENT;
	}

	dt_global_set_mac_mode = (dt_global_set_mac_mode_fn)kallsyms_lookup_name(
		"ssdk_dt_global_set_mac_mode");
	if (!dt_global_set_mac_mode) {
		pr_err("force_sgmiiplus: lookup failed: ssdk_dt_global_set_mac_mode\n");
		return -ENOENT;
	}

	pr_info("force_sgmiiplus: resolved all symbols via kallsyms\n");

	/* Stop loop briefly during the mode change to prevent races */
	ret = ssdk_mac_sw_sync_work_stop(DEV_ID);
	if (ret < 0 && ret != -0x13) {
		pr_err("force_sgmiiplus: ssdk_mac_sw_sync_work_stop failed: %d\n", ret);
		return ret;
	}

	/* Set uniphy1 hardware to SGMII+ — link flaps ~300ms */
	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);
	if (ret != 0) {
		pr_err("force_sgmiiplus: uniphy_mode_set failed: %d\n", ret);
		ssdk_mac_sw_sync_work_start(DEV_ID);
		return ret;
	}
	pr_info("force_sgmiiplus: uniphy%d set to SGMII+ 2.5G\n", UNIPHY_INDEX);

	/* Update SSDK bookkeeping so the polling loop sees SGMII+ as correct */
	port_iface_mode_set(DEV_ID, SSDK_PORT_ID, PORT_MODE_SGMIIPLUS);
	pr_info("force_sgmiiplus: port %d interface_mode set to 0x%x\n",
		SSDK_PORT_ID, PORT_MODE_SGMIIPLUS);

	dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);
	pr_info("force_sgmiiplus: uniphy%d mac_mode set to 0x%x\n",
		UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);

	/* Restart the polling loop — it now manages all ports including eth5 */
	ssdk_mac_sw_sync_work_start(DEV_ID);
	pr_info("force_sgmiiplus: MAC sync polling restarted\n");

	pr_info("force_sgmiiplus: verify: cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate\n");
	return 0;
}

static void __exit force_sgmiiplus_exit(void)
{
	if (!uniphy_mode_set)
		return;

	pr_info("force_sgmiiplus: reverting...\n");

	ssdk_mac_sw_sync_work_stop(DEV_ID);

	uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMII_CH0);

	if (port_iface_mode_set)
		port_iface_mode_set(DEV_ID, SSDK_PORT_ID, ORIG_PORT_IFACE_MODE);

	if (dt_global_set_mac_mode)
		dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, ORIG_MAC_MODE);

	ssdk_mac_sw_sync_work_start(DEV_ID);
	pr_info("force_sgmiiplus: reverted to SGMII 1G, polling restarted\n");
}

module_init(force_sgmiiplus_init);
module_exit(force_sgmiiplus_exit);
