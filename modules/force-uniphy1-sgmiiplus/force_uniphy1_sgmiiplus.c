/*
 * force_uniphy1_sgmiiplus.c - Force UCG-Fiber / UXG-Fiber uniphy1 (eth6) to SGMII+ 2.5G
 *
 * Bypasses the SSDK's SFP EEPROM validation by calling the uniphy mode set
 * function directly, then updates SSDK bookkeeping so the MAC sync polling
 * loop accepts SGMII+ as the correct mode. Port 5 (eth6) is excluded from
 * the loop's port bitmap so it can't reconfigure our port's MAC speed (the
 * loop reads 1000 from PPE due to SGMII in-band limitations and would force
 * MAC to 1G, breaking the 2.5G data path). The loop continues managing all
 * other ports (LAN + eth5 WAN) normally.
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
#include <linux/delay.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Ozark Connect");
MODULE_DESCRIPTION("Force UCG-Fiber / UXG-Fiber uniphy1 to SGMII+ 2.5G");

/* Exported by qca-ssdk.ko */
extern int ssdk_mac_sw_sync_work_stop(unsigned int dev_id);
extern int ssdk_mac_sw_sync_work_start(unsigned int dev_id);

/* Local symbols resolved via kallsyms */
typedef int (*uniphy_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, int mode);
typedef int (*port_iface_mode_set_fn)(unsigned int dev_id, unsigned long port_id, int mode);
typedef int (*dt_global_set_mac_mode_fn)(unsigned long dev_id, int uniphy_index, unsigned int mode);
typedef unsigned int (*port_bmp_get_fn)(unsigned int dev_id);
typedef void (*port_bmp_set_fn)(unsigned int dev_id, unsigned int bmp);

static uniphy_mode_set_fn uniphy_mode_set;
static port_iface_mode_set_fn port_iface_mode_set;
static dt_global_set_mac_mode_fn dt_global_set_mac_mode;
static port_bmp_get_fn port_bmp_get;
static port_bmp_set_fn port_bmp_set;

#define SSDK_UNIPHY_SGMIIPLUS 0x0c
#define SSDK_UNIPHY_SGMII_CH0 0x0f
#define UNIPHY_INDEX 1
#define SSDK_PORT_ID 5
#define DEV_ID 0
#define PORT_MODE_SGMIIPLUS 6
#define ORIG_PORT_IFACE_MODE 0x0e
#define ORIG_MAC_MODE 0x14

static unsigned int orig_port_bmp;

static int __init force_sgmiiplus_init(void)
{
	int ret;
	unsigned int bmp;

	uniphy_mode_set = (uniphy_mode_set_fn)kallsyms_lookup_name(
		"adpt_hppe_uniphy_mode_set");
	port_iface_mode_set = (port_iface_mode_set_fn)kallsyms_lookup_name(
		"_adpt_hppe_port_interface_mode_set");
	dt_global_set_mac_mode = (dt_global_set_mac_mode_fn)kallsyms_lookup_name(
		"ssdk_dt_global_set_mac_mode");
	port_bmp_get = (port_bmp_get_fn)kallsyms_lookup_name(
		"qca_ssdk_port_bmp_get");
	port_bmp_set = (port_bmp_set_fn)kallsyms_lookup_name(
		"qca_ssdk_port_bmp_set");

	if (!uniphy_mode_set || !port_iface_mode_set || !dt_global_set_mac_mode ||
	    !port_bmp_get || !port_bmp_set) {
		pr_err("force_sgmiiplus: kallsyms lookup failed\n");
		return -ENOENT;
	}

	pr_info("force_sgmiiplus: resolved all symbols\n");

	orig_port_bmp = port_bmp_get(DEV_ID);
	bmp = orig_port_bmp & ~(1u << SSDK_PORT_ID);

	ssdk_mac_sw_sync_work_stop(DEV_ID);

	port_bmp_set(DEV_ID, bmp);
	pr_info("force_sgmiiplus: port bitmap 0x%x -> 0x%x (port %d excluded)\n",
		orig_port_bmp, bmp, SSDK_PORT_ID);

	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);
	if (ret != 0) {
		pr_err("force_sgmiiplus: uniphy_mode_set failed: %d\n", ret);
		port_bmp_set(DEV_ID, orig_port_bmp);
		ssdk_mac_sw_sync_work_start(DEV_ID);
		return ret;
	}
	pr_info("force_sgmiiplus: uniphy%d set to SGMII+ 2.5G\n", UNIPHY_INDEX);

	port_iface_mode_set(DEV_ID, SSDK_PORT_ID, PORT_MODE_SGMIIPLUS);
	dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);

	msleep(1000);
	ssdk_mac_sw_sync_work_start(DEV_ID);
	pr_info("force_sgmiiplus: loop restarted (port %d excluded)\n", SSDK_PORT_ID);

	return 0;
}

static void __exit force_sgmiiplus_exit(void)
{
	if (!uniphy_mode_set)
		return;

	ssdk_mac_sw_sync_work_stop(DEV_ID);

	uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMII_CH0);

	if (port_iface_mode_set)
		port_iface_mode_set(DEV_ID, SSDK_PORT_ID, ORIG_PORT_IFACE_MODE);
	dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, ORIG_MAC_MODE);

	if (port_bmp_set)
		port_bmp_set(DEV_ID, orig_port_bmp);

	ssdk_mac_sw_sync_work_start(DEV_ID);
	pr_info("force_sgmiiplus: reverted, loop restarted with full bitmap 0x%x\n",
		orig_port_bmp);
}

module_init(force_sgmiiplus_init);
module_exit(force_sgmiiplus_exit);
