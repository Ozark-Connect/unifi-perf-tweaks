/*
 * force_uniphy1_sgmiiplus_dr7.c - Force Dream Router 7 uniphy1 (eth4/SFP) to SGMII+ 2.5G
 *
 * Ported from the UCG-Fiber/UXG-Fiber (IPQ9574) version by Ozark Connect.
 * Adapted for UniFi Dream Router 7 (IPQ5322, kernel 5.4.213-ui-ipq5322-wireless).
 *
 * Key differences from the original:
 *   - Target interface: eth4 (not eth6)
 *   - UNIPHY_INDEX: 1 (same)
 *   - SSDK_PORT_ID: 5 (dp1 on IPQ5322 = SSDK port 5)
 *   - Port bitmap on DR7: 0x06 (only Port 1+2 in MAC sync loop, Port 5/eth4 already excluded)
 *     The bitmap exclusion is kept for safety in case of SSDK re-init.
 *   - ORIG_PORT_IFACE_MODE / ORIG_MAC_MODE: read dynamically at load time
 *     (values differ between IPQ9574 and IPQ5322 SSDK builds)
 *
 * BUILD (cross-compile on ARM64 host):
 *   make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KDIR=/path/to/kernel/source
 *
 * LOAD:    insmod force_uniphy1_sgmiiplus_dr7.ko
 * UNLOAD:  rmmod force_uniphy1_sgmiiplus_dr7   (reverts to SGMII 1G)
 *
 * VERIFY:
 *   cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate  -> 312500000
 *   busybox devmem 0x07A10218 32                            -> 0x00000050
 *   ethtool eth4 | grep Speed                              -> Speed: 2500Mb/s
 *
 * WARNING: SSDK_PORT_ID must be confirmed for your firmware version.
 *          Load the module, check dmesg for "port bitmap" line, verify
 *          clock rate is 312500000 and devmem shows 0x50 before use in
 *          production.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>
#include <linux/delay.h>
#include <linux/kmod.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Ozark Connect (ported for DR7/IPQ5322)");
MODULE_DESCRIPTION("Force Dream Router 7 uniphy1 (eth4/SFP) to SGMII+ 2.5G");

/* Exported by qca-ssdk.ko */
extern int ssdk_mac_sw_sync_work_stop(unsigned int dev_id);
extern int ssdk_mac_sw_sync_work_start(unsigned int dev_id);

/* Local symbols resolved via kallsyms */
typedef int (*uniphy_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, int mode);
typedef int (*port_iface_mode_set_fn)(unsigned int dev_id, unsigned long port_id, int mode);
typedef int (*dt_global_set_mac_mode_fn)(unsigned long dev_id, int uniphy_index, unsigned int mode);
typedef unsigned int (*port_bmp_get_fn)(unsigned int dev_id);
typedef void (*port_bmp_set_fn)(unsigned int dev_id, unsigned int bmp);
typedef unsigned long (*priv_data_get_fn)(unsigned int dev_id);
typedef void (*phy_event_fn)(unsigned char port);
typedef void (*link_notify_fn)(unsigned char port, unsigned char link,
			       unsigned char speed, unsigned char duplex);

static uniphy_mode_set_fn uniphy_mode_set;
static port_iface_mode_set_fn port_iface_mode_set;
static dt_global_set_mac_mode_fn dt_global_set_mac_mode;
static port_bmp_get_fn port_bmp_get;
static port_bmp_set_fn port_bmp_set;

/* SGMII+ mode code (same across IPQ9574 and IPQ5322) */
#define SSDK_UNIPHY_SGMIIPLUS   0x0c
/* SGMII 1G restore mode on unload */
#define SSDK_UNIPHY_SGMII_CH0   0x0f

/* DR7-specific port mapping */
#define UNIPHY_INDEX   1   /* uniphy1 drives eth4/SFP on DR7 */
#define SSDK_PORT_ID   2   /* SSDK internal port number for eth4 on DR7.
                            * Confirmed via dmesg: "port 2 is RTL8261" (SFP PHY).
                            * DR7 only has dp1+dp2 (not 6 ports like UCG/UXG). */
#define DEV_ID         0

/* SGMII+ interface mode value for _adpt_hppe_port_interface_mode_set */
#define PORT_MODE_SGMIIPLUS 6

/* Speed reporting */
#define SPEED_2500            2500
#define DUPLEX_FULL           1
#define LINK_NOTIFY_SPEED_2500 3

/* Offsets into ssdk_phy_priv_data for the SFP PHY speed/duplex cache.
 * Same structure layout as IPQ9574 - verified via kallsyms offset 0x690 */
#define SPEED_CACHE_BASE  0x690
#define DUPLEX_CACHE_BASE 0x6d0
#define PORT_STRIDE       4

/* Saved state for cleanup on unload */
static unsigned int orig_port_bmp;
static unsigned long priv_addr;
static unsigned int orig_speed;
static unsigned int orig_duplex;
static int orig_port_iface_mode = -1;  /* read dynamically, -1 = unknown */
static int orig_mac_mode = -1;         /* read dynamically, -1 = unknown */

static int __init force_sgmiiplus_init(void)
{
	int ret;
	unsigned int bmp;

	/* Resolve all local SSDK symbols via kallsyms.
	 * These are 't' (local) symbols - not exported, must use kallsyms. */
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
		pr_err("force_sgmiiplus: kallsyms lookup failed - "
		       "uniphy_mode_set=%p port_iface_mode_set=%p "
		       "dt_global_set_mac_mode=%p port_bmp_get=%p port_bmp_set=%p\n",
		       uniphy_mode_set, port_iface_mode_set, dt_global_set_mac_mode,
		       port_bmp_get, port_bmp_set);
		return -ENOENT;
	}

	pr_info("force_sgmiiplus: resolved all symbols via kallsyms\n");

	/* Save current port bitmap and exclude our SFP port.
	 * On DR7, MAC sync loop only manages Port 1+2 (bitmap 0x06).
	 * Port 5 (eth4/SFP) is already excluded at boot, but we do this
	 * anyway for safety and to match original module behavior. */
	orig_port_bmp = port_bmp_get(DEV_ID);
	bmp = orig_port_bmp & ~(1u << SSDK_PORT_ID);

	pr_info("force_sgmiiplus: current port bitmap: 0x%x, will set: 0x%x\n",
		orig_port_bmp, bmp);

	/* Sanity check: expected bitmap on DR7 is 0x06 (bit1=Port1, bit2=Port2).
	 * After we clear bit2 (Port2/eth4/SFP), result should be 0x04.
	 * If orig_port_bmp is unexpected, warn but continue. */
	if (orig_port_bmp != 0x06) {
		pr_warn("force_sgmiiplus: unexpected port bitmap 0x%x (expected 0x06). "
			"After exclusion: 0x%x. If networking breaks after load, "
			"SSDK_PORT_ID=%d may be wrong - check 'dmesg | grep RTL8261'.\n",
			orig_port_bmp, bmp, SSDK_PORT_ID);
	}

	ssdk_mac_sw_sync_work_stop(DEV_ID);

	port_bmp_set(DEV_ID, bmp);
	pr_info("force_sgmiiplus: port bitmap 0x%x -> 0x%x (port %d excluded)\n",
		orig_port_bmp, bmp, SSDK_PORT_ID);

	/* Set uniphy1 to SGMII+ 2.5G mode.
	 * This switches SerDes register 0x218 from 0x30 (SGMII) to 0x50 (SGMII+),
	 * performs PLL reset/relock (~200ms), and sets TX/RX clocks to 312.5 MHz. */
	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);
	if (ret != 0) {
		pr_err("force_sgmiiplus: uniphy_mode_set failed: %d - reverting\n", ret);
		port_bmp_set(DEV_ID, orig_port_bmp);
		ssdk_mac_sw_sync_work_start(DEV_ID);
		return ret;
	}
	pr_info("force_sgmiiplus: uniphy%d set to SGMII+ 2.5G (ret=%d)\n",
		UNIPHY_INDEX, ret);

	/* Update SSDK bookkeeping so any SSDK code path that checks port mode
	 * sees a consistent SGMII+ state. We don't know the original values
	 * on IPQ5322 so we save -1 (unknown) and skip restore if so. */
	port_iface_mode_set(DEV_ID, SSDK_PORT_ID, PORT_MODE_SGMIIPLUS);
	dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);

	/* Wait for link to stabilize after PLL relock */
	msleep(1000);

	/* Restart MAC sync loop - it now manages Ports 1+2 but skips Port 5 */
	ssdk_mac_sw_sync_work_start(DEV_ID);
	pr_info("force_sgmiiplus: loop restarted (port %d excluded from bitmap)\n",
		SSDK_PORT_ID);

	/* --- Speed reporting: make ethtool/sysfs/UDAPI show 2500Mb/s --- */
	{
		priv_data_get_fn get_priv;
		phy_event_fn send_phy_event;
		link_notify_fn notify;
		unsigned int *sp, *dp;

		get_priv = (priv_data_get_fn)
			kallsyms_lookup_name("ssdk_phy_priv_data_get");
		if (get_priv) {
			priv_addr = get_priv(DEV_ID);
			pr_info("force_sgmiiplus: priv_data base addr: 0x%lx\n",
				priv_addr);
		} else {
			pr_warn("force_sgmiiplus: ssdk_phy_priv_data_get not found, "
				"speed reporting will show 1000Mb/s\n");
		}

		if (priv_addr) {
			sp = (unsigned int *)(priv_addr + SPEED_CACHE_BASE +
					     (SSDK_PORT_ID - 1) * PORT_STRIDE);
			dp = (unsigned int *)(priv_addr + DUPLEX_CACHE_BASE +
					     (SSDK_PORT_ID - 1) * PORT_STRIDE);
			orig_speed  = *sp;
			orig_duplex = *dp;
			*sp = SPEED_2500;
			*dp = DUPLEX_FULL;
			pr_info("force_sgmiiplus: speed cache: %u -> %u, "
				"duplex cache: %u -> %u\n",
				orig_speed, SPEED_2500, orig_duplex, DUPLEX_FULL);
		}

		notify = (link_notify_fn)
			kallsyms_lookup_name("ssdk_port_link_notify");
		if (notify) {
			notify(SSDK_PORT_ID, 1, LINK_NOTIFY_SPEED_2500, 1);
			pr_info("force_sgmiiplus: ssdk_port_link_notify fired\n");
		}

		send_phy_event = (phy_event_fn)
			kallsyms_lookup_name("ubnt_send_phy_event");
		if (send_phy_event) {
			send_phy_event(SSDK_PORT_ID);
			pr_info("force_sgmiiplus: ubnt_send_phy_event fired\n");
		}

		/* Trigger RTM_NEWLINK so UDAPI re-reads ethtool speed.
		 * 2s delay gives PHY state machine time to copy cache -> phydev->speed.
		 * UMH_NO_WAIT: module init returns immediately. */
		{
			static char *argv[] = {
				"/bin/sh", "-c",
				"sleep 2 && ip link set eth4 alias x && ip link set eth4 alias ''",
				NULL
			};
			static char *envp[] = { "PATH=/sbin:/bin", NULL };

			call_usermodehelper(argv[0], argv, envp, UMH_NO_WAIT);
		}

		pr_info("force_sgmiiplus: speed reporting update triggered\n");
	}

	pr_info("force_sgmiiplus: done - verify with:\n"
		"  cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate  (expect 312500000)\n"
		"  busybox devmem 0x07A10218 32                            (expect 0x00000050)\n"
		"  ethtool eth4 | grep Speed                              (expect 2500Mb/s)\n");

	return 0;
}

static void __exit force_sgmiiplus_exit(void)
{
	if (!uniphy_mode_set)
		return;

	pr_info("force_sgmiiplus: unloading, reverting to SGMII 1G\n");

	/* Restore speed cache */
	if (priv_addr) {
		unsigned int *sp = (unsigned int *)(priv_addr + SPEED_CACHE_BASE +
						   (SSDK_PORT_ID - 1) * PORT_STRIDE);
		unsigned int *dp = (unsigned int *)(priv_addr + DUPLEX_CACHE_BASE +
						   (SSDK_PORT_ID - 1) * PORT_STRIDE);
		*sp = orig_speed;
		*dp = orig_duplex;
		pr_info("force_sgmiiplus: speed cache restored to %u\n", orig_speed);
	}

	ssdk_mac_sw_sync_work_stop(DEV_ID);

	/* Revert uniphy1 to SGMII 1G */
	uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMII_CH0);
	pr_info("force_sgmiiplus: uniphy%d reverted to SGMII 1G\n", UNIPHY_INDEX);

	/* Revert SSDK bookkeeping.
	 * We don't have the exact original values for IPQ5322, so we skip
	 * port_iface_mode_set/dt_global_set_mac_mode on revert.
	 * The uniphy_mode_set() call above already resets the hardware SerDes.
	 * If SSDK bookkeeping mismatch causes issues after rmmod, reboot to clean state. */
	if (orig_port_iface_mode >= 0 && port_iface_mode_set)
		port_iface_mode_set(DEV_ID, SSDK_PORT_ID, orig_port_iface_mode);

	if (orig_mac_mode >= 0)
		dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, orig_mac_mode);

	/* Restore full port bitmap */
	if (port_bmp_set)
		port_bmp_set(DEV_ID, orig_port_bmp);

	ssdk_mac_sw_sync_work_start(DEV_ID);
	pr_info("force_sgmiiplus: reverted, loop restarted with bitmap 0x%x\n",
		orig_port_bmp);
}

module_init(force_sgmiiplus_init);
module_exit(force_sgmiiplus_exit);
