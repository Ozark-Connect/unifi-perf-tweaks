/*
 * force_uniphy1_sgmiiplus.c - Force UCG-Fiber / UXG-Fiber uniphy1 (eth6) to SGMII+ 2.5G
 *
 * Bypasses the SSDK's SFP EEPROM validation by calling the uniphy mode set
 * function directly, then updates SSDK bookkeeping so the MAC sync polling
 * loop accepts SGMII+ as the correct mode. Port 5 (eth6) is excluded from
 * the loop's port bitmap so it can't reconfigure our port's MAC speed (the
 * loop reads 1000 from PPE due to SGMII in-band limitations and would force
 * MAC to 1G, breaking the 2.5G data path). The loop continues managing all
 * other ports (LAN + eth5 SFP+ trunk) normally.
 *
 * Target: UCG-Fiber / UXG-Fiber, IPQ9574, kernel 5.4.213-ui-ipq9574
 * Module: qca-ssdk.ko must be loaded
 *
 * BUILD:   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
 * LOAD:    insmod force_uniphy1_sgmiiplus.ko
 * UNLOAD:  rmmod force_uniphy1_sgmiiplus  (reverts to SGMII 1G)
 * VERIFY:  cat /sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate
 *          (should show 312500000 after load, 125000000 after unload)
 *
 * Also maintains the SSDK fake-PHY link, speed, and duplex caches. Mode
 * changes follow the vendor sequence: update the global mode, select the
 * UniPHY1 clock source, program the SerDes, then configure the port-5 MAC
 * type, mux, reset, flow control, and speed clock. A small kthread reads
 * both the physical UniPHY mode and its PCS link bit. If a later QCA SFP
 * event changes UniPHY1 back to native SGMII, the thread atomically
 * reasserts the complete SGMII+ path before resynchronizing the MAC.
 * GPON RX_LOS remains deliberately ignored because it describes the PON
 * optical state, not the Ethernet host-side link.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/kthread.h>
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Ozark Connect");
MODULE_DESCRIPTION("Force UCG-Fiber / UXG-Fiber uniphy1 to SGMII+ 2.5G");

/* Exported by qca-ssdk.ko */
extern int ssdk_mac_sw_sync_work_stop(unsigned int dev_id);
extern int ssdk_mac_sw_sync_work_start(unsigned int dev_id);

/* Local symbols resolved via kallsyms */
typedef int (*uniphy_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, int mode);
typedef int (*port_iface_mode_set_fn)(unsigned int dev_id, unsigned int port_id, int mode);
typedef int (*port_iface_mode_get_fn)(unsigned int dev_id, unsigned int port_id, int *mode);
typedef unsigned int (*dt_global_get_mac_mode_fn)(unsigned int dev_id,
						  unsigned int uniphy_index);
typedef int (*dt_global_set_mac_mode_fn)(unsigned int dev_id,
					 unsigned int uniphy_index,
					 unsigned int mode);
typedef unsigned int (*port_bmp_get_fn)(unsigned int dev_id);
typedef void (*port_bmp_set_fn)(unsigned int dev_id, unsigned int bmp);
typedef int (*port_feature_get_fn)(unsigned int dev_id, unsigned int port_id,
				   unsigned int feature);
typedef unsigned long (*priv_data_get_fn)(unsigned int dev_id);
typedef void (*phy_event_fn)(unsigned char port);
typedef void (*link_notify_fn)(unsigned char port, unsigned char link,
			       unsigned char speed, unsigned char duplex);

typedef int (*uniphy_status_get_fn)(unsigned int dev_id,
				    unsigned int uniphy_index,
				    unsigned int *status);
typedef int (*uniphy_phy_mode_get_fn)(unsigned int dev_id,
				     unsigned int uniphy_index,
				     unsigned int *mode);
typedef int (*port_control_set_fn)(unsigned int dev_id,
				   unsigned int port_id,
				   int value);
typedef int (*port_mux_mac_type_set_fn)(unsigned int dev_id,
					unsigned int port_id,
					unsigned int mode0,
					unsigned int mode1,
					unsigned int mode2);
typedef unsigned int (*port_mac_type_get_fn)(unsigned int dev_id,
					     unsigned int port_id);
typedef void (*port5_clock_source_set_fn)(void);
typedef void (*port_speed_clock_set_fn)(unsigned int dev_id,
					unsigned int port_id,
					int speed);
static uniphy_mode_set_fn uniphy_mode_set;
static port_iface_mode_set_fn port_iface_mode_force;
static port_iface_mode_set_fn port_iface_mode_set_raw;
static port_iface_mode_get_fn port_iface_mode_get;
static dt_global_get_mac_mode_fn dt_global_get_mac_mode;
static dt_global_set_mac_mode_fn dt_global_set_mac_mode;
static port_bmp_get_fn port_bmp_get;
static port_bmp_set_fn port_bmp_set;
static port_feature_get_fn port_feature_get;
static uniphy_status_get_fn uniphy_status_get;
static uniphy_phy_mode_get_fn uniphy_phy_mode_get;
static priv_data_get_fn priv_data_get;
static phy_event_fn send_phy_event;
static link_notify_fn link_notify;
static port_control_set_fn port_txmac_set;
static port_control_set_fn port_rxmac_set;
static port_control_set_fn port_bridge_txmac_set;
static port_control_set_fn port_mac_speed_set;
static port_control_set_fn port_mac_duplex_set;
static port_mux_mac_type_set_fn port_mux_mac_type_set;
static port_mac_type_get_fn port_mac_type_get;
static port5_clock_source_set_fn port5_clock_source_set;
static port_speed_clock_set_fn port_speed_clock_set;

#define SSDK_UNIPHY_SGMIIPLUS 0x0c
#define UNIPHY_INDEX 1
#define SSDK_PORT_ID 5
#define DEV_ID 0
#define PORT_MODE_SGMIIPLUS 6
#define PORT_INTERFACE_MODE_AUTO 17
#define PHY_F_FORCE_INTERFACE_MODE (1u << 9)

#define SPEED_2500   2500
#define SSDK_DUPLEX_FULL 1
#define LINK_NOTIFY_SPEED_2500 3
#define PORT_XGMAC_TYPE 2

#define LINK_CACHE_BASE   0x650
#define SPEED_CACHE_BASE  0x690
#define DUPLEX_CACHE_BASE 0x6d0
#define PORT_STRIDE       4
#define UNIPHY_PCS_LINK_BIT (1u << 7)
#define LINK_MONITOR_INTERVAL_MS 1000
#define UNIPHY_PHY_MODE_MASK 0x70
#define UNIPHY_PHY_MODE_SGMIIPLUS 0x50


static unsigned int orig_port_bmp;
static int orig_port_iface_mode;
static unsigned int orig_mac_mode;
static bool orig_force_interface_mode;
static unsigned int orig_port_mac_type;
static unsigned long priv_addr;
static unsigned int *link_cache;
static unsigned int *speed_cache;
static unsigned int *duplex_cache;
static unsigned int orig_link;
static unsigned int orig_speed;
static unsigned int orig_duplex;
static struct task_struct *link_monitor_task;
static bool recovery_sync_worker_stopped;

static void force_sgmiiplus_notify_host_link(unsigned int link)
{
	if (link_notify)
		link_notify(SSDK_PORT_ID, link,
			    link ? LINK_NOTIFY_SPEED_2500 : 0,
			    link ? SSDK_DUPLEX_FULL : 0);

	if (send_phy_event)
		send_phy_event(SSDK_PORT_ID);
}

static int force_sgmiiplus_set_data_path(unsigned int link)
{
	int ret;

	if (!link) {
		ret = port_bridge_txmac_set(DEV_ID, SSDK_PORT_ID, 0);
		if (ret) {
			pr_err("force_sgmiiplus: failed to disable bridge TX MAC: %d\n",
			       ret);
			return ret;
		}

		msleep(10);
		ret = port_txmac_set(DEV_ID, SSDK_PORT_ID, 0);
		if (ret) {
			pr_err("force_sgmiiplus: failed to disable TX MAC: %d\n",
			       ret);
			return ret;
		}

		ret = port_rxmac_set(DEV_ID, SSDK_PORT_ID, 0);
		if (ret) {
			pr_err("force_sgmiiplus: failed to disable RX MAC: %d\n",
			       ret);
			return ret;
		}

		pr_info("force_sgmiiplus: MAC data path disabled\n");
		return 0;
	}

	ret = port_txmac_set(DEV_ID, SSDK_PORT_ID, 0);
	if (ret) {
		pr_err("force_sgmiiplus: failed to pause TX MAC: %d\n", ret);
		return ret;
	}

	ret = port_mac_speed_set(DEV_ID, SSDK_PORT_ID, SPEED_2500);
	if (ret) {
		pr_err("force_sgmiiplus: failed to set MAC speed: %d\n", ret);
		return ret;
	}

	ret = port_mac_duplex_set(DEV_ID, SSDK_PORT_ID, SSDK_DUPLEX_FULL);
	if (ret) {
		pr_err("force_sgmiiplus: failed to set MAC duplex: %d\n", ret);
		return ret;
	}

	ret = port_txmac_set(DEV_ID, SSDK_PORT_ID, 1);
	if (ret) {
		pr_err("force_sgmiiplus: failed to enable TX MAC: %d\n", ret);
		return ret;
	}

	ret = port_rxmac_set(DEV_ID, SSDK_PORT_ID, 1);
	if (ret) {
		pr_err("force_sgmiiplus: failed to enable RX MAC: %d\n", ret);
		return ret;
	}

	ret = port_bridge_txmac_set(DEV_ID, SSDK_PORT_ID, 1);
	if (ret) {
		pr_err("force_sgmiiplus: failed to enable bridge TX MAC: %d\n",
		       ret);
		return ret;
	}

	pr_info("force_sgmiiplus: MAC data path enabled at 2500/full\n");
	return 0;
}

static int force_sgmiiplus_program_mode(unsigned int mode,
					unsigned int speed)
{
	unsigned int mode0;
	unsigned int mode2;
	int ret;

	mode0 = dt_global_get_mac_mode(DEV_ID, 0);
	mode2 = dt_global_get_mac_mode(DEV_ID, 2);

	ret = dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, mode);
	if (ret) {
		pr_err("force_sgmiiplus: global mode update failed: %d\n", ret);
		return ret;
	}

	port5_clock_source_set();

	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, mode);
	if (ret) {
		pr_err("force_sgmiiplus: uniphy mode update failed: %d\n", ret);
		return ret;
	}

	ret = port_mux_mac_type_set(DEV_ID, SSDK_PORT_ID, mode0, mode, mode2);
	if (ret) {
		pr_err("force_sgmiiplus: vendor MAC/mux transition failed: %d\n",
		       ret);
		return ret;
	}

	port_speed_clock_set(DEV_ID, SSDK_PORT_ID, speed);
	pr_info("force_sgmiiplus: vendor mode transition complete: mode=0x%x mac_type=%u speed=%u\n",
		mode, port_mac_type_get(DEV_ID, SSDK_PORT_ID), speed);

	return 0;
}

static int force_sgmiiplus_ensure_mode(bool *reapplied)
{
	unsigned int phy_mode = 0;
	unsigned int global_mode;
	unsigned int bmp;
	unsigned int mac_type;
	int port_mode;
	bool force_mode;
	bool bitmap_drift;
	int ret;
	int start_ret;

	*reapplied = false;

	ret = uniphy_phy_mode_get(DEV_ID, UNIPHY_INDEX, &phy_mode);
	if (ret)
		return ret;

	ret = port_iface_mode_get(DEV_ID, SSDK_PORT_ID, &port_mode);
	if (ret)
		return ret;

	global_mode = dt_global_get_mac_mode(DEV_ID, UNIPHY_INDEX);
	force_mode = port_feature_get(DEV_ID, SSDK_PORT_ID,
				      PHY_F_FORCE_INTERFACE_MODE) != 0;
	bmp = port_bmp_get(DEV_ID);
	mac_type = port_mac_type_get(DEV_ID, SSDK_PORT_ID);
	bitmap_drift = (bmp & (1u << SSDK_PORT_ID)) != 0;

	if ((phy_mode & UNIPHY_PHY_MODE_MASK) ==
		    UNIPHY_PHY_MODE_SGMIIPLUS &&
	    port_mode == PORT_MODE_SGMIIPLUS &&
	    global_mode == SSDK_UNIPHY_SGMIIPLUS && force_mode &&
	    mac_type == PORT_XGMAC_TYPE && !bitmap_drift) {
		if (!recovery_sync_worker_stopped)
			return 0;

		ret = ssdk_mac_sw_sync_work_start(DEV_ID);
		if (ret)
			return ret;

		recovery_sync_worker_stopped = false;
		*reapplied = true;
		pr_info("force_sgmiiplus: sync worker recovered after mode repair\n");
		return 0;
	}

	pr_warn("force_sgmiiplus: mode drift detected: phy=0x%x port=0x%x global=0x%x force=%u mac=%u bitmap=0x%x; reasserting SGMII+\n",
		phy_mode, port_mode, global_mode, force_mode ? 1 : 0,
		mac_type, bmp);

	ret = force_sgmiiplus_set_data_path(0);
	if (ret)
		return ret;
	WRITE_ONCE(*link_cache, 0);

	ret = ssdk_mac_sw_sync_work_stop(DEV_ID);
	if (ret) {
		pr_err("force_sgmiiplus: failed to stop sync worker during mode recovery: %d\n",
		       ret);
		return ret;
	}
	recovery_sync_worker_stopped = true;

	bmp = port_bmp_get(DEV_ID);
	port_bmp_set(DEV_ID, bmp & ~(1u << SSDK_PORT_ID));

	ret = port_iface_mode_force(DEV_ID, SSDK_PORT_ID,
				    PORT_MODE_SGMIIPLUS);
	if (ret) {
		pr_err("force_sgmiiplus: failed to restore forced port mode: %d\n",
		       ret);
		goto restart_worker;
	}

	ret = force_sgmiiplus_program_mode(SSDK_UNIPHY_SGMIIPLUS,
					   SPEED_2500);
	if (ret)
		goto restart_worker;

	msleep(1000);

restart_worker:
	start_ret = ssdk_mac_sw_sync_work_start(DEV_ID);
	if (start_ret) {
		pr_err("force_sgmiiplus: failed to restart sync worker during mode recovery: %d\n",
		       start_ret);
		if (!ret)
			ret = start_ret;
	} else {
		recovery_sync_worker_stopped = false;
	}
	if (ret)
		return ret;

	*reapplied = true;
	pr_info("force_sgmiiplus: SGMII+ mode restored after drift\n");
	return 0;
}

static int force_sgmiiplus_sync_host_link(bool announce)
{
	unsigned int pcs_status = 0;
	unsigned int host_link;
	unsigned int old_link;
	unsigned int old_speed;
	unsigned int old_duplex;
	bool update_required;
	int ret;

	ret = uniphy_status_get(DEV_ID, UNIPHY_INDEX, &pcs_status);
	if (ret)
		return ret;

	host_link = (pcs_status & UNIPHY_PCS_LINK_BIT) ? 1 : 0;
	old_link = READ_ONCE(*link_cache);
	old_speed = READ_ONCE(*speed_cache);
	old_duplex = READ_ONCE(*duplex_cache);
	update_required = announce || old_link != host_link ||
			  old_speed != SPEED_2500 ||
			  old_duplex != SSDK_DUPLEX_FULL;

	if (update_required) {
		ret = force_sgmiiplus_set_data_path(host_link);
		if (ret)
			return ret;
	}

	WRITE_ONCE(*speed_cache, SPEED_2500);
	WRITE_ONCE(*duplex_cache, SSDK_DUPLEX_FULL);
	WRITE_ONCE(*link_cache, host_link);

	if (announce || old_link != host_link)
		pr_info("force_sgmiiplus: PCS status 0x%08x, host link %u -> %u\n",
			pcs_status, old_link, host_link);

	if (update_required)
		force_sgmiiplus_notify_host_link(host_link);

	return 0;
}

static int force_sgmiiplus_link_monitor(void *unused)
{
	bool mode_failed = false;
	bool read_failed = false;
	bool mode_reapplied;
	int ret;

	while (!kthread_should_stop()) {
		ret = force_sgmiiplus_ensure_mode(&mode_reapplied);
		if (ret) {
			if (!mode_failed)
				pr_err("force_sgmiiplus: hardware mode synchronization failed: %d\n",
				       ret);
			mode_failed = true;
			goto sleep;
		}
		if (mode_failed) {
			pr_info("force_sgmiiplus: hardware mode synchronization recovered\n");
			mode_failed = false;
		}

		ret = force_sgmiiplus_sync_host_link(mode_reapplied);
		if (ret && !read_failed) {
			pr_err("force_sgmiiplus: host link synchronization failed: %d\n",
			       ret);
			read_failed = true;
		} else if (!ret && read_failed) {
			pr_info("force_sgmiiplus: PCS status reads recovered\n");
			read_failed = false;
		}

sleep:
		if (msleep_interruptible(LINK_MONITOR_INTERVAL_MS) &&
		    kthread_should_stop())
			break;
	}

	return 0;
}

static void force_sgmiiplus_restore_cache(void)
{
	if (!link_cache)
		return;

	WRITE_ONCE(*speed_cache, orig_speed);
	WRITE_ONCE(*duplex_cache, orig_duplex);
	WRITE_ONCE(*link_cache, orig_link);
	pr_info("force_sgmiiplus: cache restored link=%u speed=%u duplex=%u\n",
		orig_link, orig_speed, orig_duplex);
}

static int force_sgmiiplus_restore_interface(void)
{
	int ret = 0;
	int err;

	if (orig_force_interface_mode) {
		err = port_iface_mode_force(DEV_ID, SSDK_PORT_ID,
					    orig_port_iface_mode);
	} else {
		err = port_iface_mode_force(DEV_ID, SSDK_PORT_ID,
					    PORT_INTERFACE_MODE_AUTO);
		if (!err)
			err = port_iface_mode_set_raw(DEV_ID, SSDK_PORT_ID,
						      orig_port_iface_mode);
	}
	if (err) {
		pr_err("force_sgmiiplus: failed to restore port mode: %d\n", err);
		ret = err;
	}

	err = force_sgmiiplus_program_mode(orig_mac_mode, 1000);
	if (err) {
		pr_err("force_sgmiiplus: failed to restore vendor mode path: %d\n",
		       err);
		if (!ret)
			ret = err;
	}

	return ret;
}

static int __init force_sgmiiplus_init(void)
{
	int ret;
	int restore_ret;
	unsigned int bmp;

	uniphy_mode_set = (uniphy_mode_set_fn)kallsyms_lookup_name(
		"adpt_hppe_uniphy_mode_set");
	port_iface_mode_force = (port_iface_mode_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_interface_mode_set");
	port_iface_mode_set_raw = (port_iface_mode_set_fn)kallsyms_lookup_name(
		"_adpt_hppe_port_interface_mode_set");
	port_iface_mode_get = (port_iface_mode_get_fn)kallsyms_lookup_name(
		"adpt_hppe_port_interface_mode_get");
	dt_global_get_mac_mode = (dt_global_get_mac_mode_fn)kallsyms_lookup_name(
		"ssdk_dt_global_get_mac_mode");
	dt_global_set_mac_mode = (dt_global_set_mac_mode_fn)kallsyms_lookup_name(
		"ssdk_dt_global_set_mac_mode");
	port_bmp_get = (port_bmp_get_fn)kallsyms_lookup_name(
		"qca_ssdk_port_bmp_get");
	port_bmp_set = (port_bmp_set_fn)kallsyms_lookup_name(
		"qca_ssdk_port_bmp_set");
	port_feature_get = (port_feature_get_fn)kallsyms_lookup_name(
		"hsl_port_feature_get");
	port_mux_mac_type_set = (port_mux_mac_type_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_mux_mac_type_set");
	port_mac_type_get = (port_mac_type_get_fn)kallsyms_lookup_name(
		"qca_hppe_port_mac_type_get");
	port5_clock_source_set = (port5_clock_source_set_fn)kallsyms_lookup_name(
		"ssdk_uniphy_port5_clock_source_set");
	port_speed_clock_set = (port_speed_clock_set_fn)kallsyms_lookup_name(
		"adpt_hppe_gcc_port_speed_clock_set");
	uniphy_status_get = (uniphy_status_get_fn)kallsyms_lookup_name(
		"hppe_uniphy_channel0_input_output_6_get");
	uniphy_phy_mode_get = (uniphy_phy_mode_get_fn)kallsyms_lookup_name(
		"hppe_uniphy_phy_mode_ctrl_get");
	priv_data_get = (priv_data_get_fn)kallsyms_lookup_name(
		"ssdk_phy_priv_data_get");
	link_notify = (link_notify_fn)kallsyms_lookup_name(
		"ssdk_port_link_notify");
	send_phy_event = (phy_event_fn)kallsyms_lookup_name(
		"ubnt_send_phy_event");
	port_txmac_set = (port_control_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_txmac_status_set");
	port_rxmac_set = (port_control_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_rxmac_status_set");
	port_bridge_txmac_set = (port_control_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_bridge_txmac_set");
	port_mac_speed_set = (port_control_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_mac_speed_set");
	port_mac_duplex_set = (port_control_set_fn)kallsyms_lookup_name(
		"adpt_hppe_port_mac_duplex_set");

	if (!uniphy_mode_set || !port_iface_mode_force ||
	    !port_iface_mode_set_raw || !port_iface_mode_get ||
	    !dt_global_get_mac_mode || !dt_global_set_mac_mode ||
	    !port_bmp_get || !port_bmp_set || !port_feature_get ||
	    !port_mux_mac_type_set || !port_mac_type_get ||
	    !port5_clock_source_set || !port_speed_clock_set ||
	    !uniphy_status_get || !uniphy_phy_mode_get || !priv_data_get ||
	    !port_txmac_set || !port_rxmac_set || !port_bridge_txmac_set ||
	    !port_mac_speed_set || !port_mac_duplex_set) {
		pr_err("force_sgmiiplus: kallsyms lookup failed\n");
		return -ENOENT;
	}

	priv_addr = priv_data_get(DEV_ID);
	if (!priv_addr) {
		pr_err("force_sgmiiplus: SSDK private data unavailable\n");
		return -ENODEV;
	}

	link_cache = (unsigned int *)(priv_addr + LINK_CACHE_BASE +
				      (SSDK_PORT_ID - 1) * PORT_STRIDE);
	speed_cache = (unsigned int *)(priv_addr + SPEED_CACHE_BASE +
				       (SSDK_PORT_ID - 1) * PORT_STRIDE);
	duplex_cache = (unsigned int *)(priv_addr + DUPLEX_CACHE_BASE +
					(SSDK_PORT_ID - 1) * PORT_STRIDE);
	orig_link = READ_ONCE(*link_cache);
	orig_speed = READ_ONCE(*speed_cache);
	orig_duplex = READ_ONCE(*duplex_cache);

	orig_port_bmp = port_bmp_get(DEV_ID);
	ret = port_iface_mode_get(DEV_ID, SSDK_PORT_ID,
				  &orig_port_iface_mode);
	if (ret) {
		pr_err("force_sgmiiplus: failed to read port mode: %d\n", ret);
		return ret;
	}
	orig_mac_mode = dt_global_get_mac_mode(DEV_ID, UNIPHY_INDEX);
	orig_force_interface_mode =
		port_feature_get(DEV_ID, SSDK_PORT_ID,
				 PHY_F_FORCE_INTERFACE_MODE) != 0;
	orig_port_mac_type = port_mac_type_get(DEV_ID, SSDK_PORT_ID);

	pr_info("force_sgmiiplus: resolved symbols; original port_mode=0x%x mac_mode=0x%x mac_type=%u force=%u link=%u speed=%u duplex=%u\n",
		orig_port_iface_mode, orig_mac_mode, orig_port_mac_type,
		orig_force_interface_mode ? 1 : 0,
		orig_link, orig_speed, orig_duplex);

	ret = ssdk_mac_sw_sync_work_stop(DEV_ID);
	if (ret) {
		pr_err("force_sgmiiplus: failed to stop sync worker: %d\n", ret);
		return ret;
	}

	bmp = orig_port_bmp & ~(1u << SSDK_PORT_ID);
	port_bmp_set(DEV_ID, bmp);
	pr_info("force_sgmiiplus: port bitmap 0x%x -> 0x%x (port %d excluded)\n",
		orig_port_bmp, bmp, SSDK_PORT_ID);

	/*
	 * Use the public setter, not only the raw bookkeeping setter. It marks
	 * PHY_F_FORCE_INTERFACE_MODE, so SFP EEPROM auto-detection cannot switch
	 * this port back to 1000BASE-X if a later service restores the bitmap.
	 */
	ret = port_iface_mode_force(DEV_ID, SSDK_PORT_ID,
				    PORT_MODE_SGMIIPLUS);
	if (ret) {
		pr_err("force_sgmiiplus: forced port mode failed: %d\n", ret);
		goto restore;
	}

	ret = force_sgmiiplus_set_data_path(0);
	if (ret)
		goto restore;
	WRITE_ONCE(*link_cache, 0);

	ret = force_sgmiiplus_program_mode(SSDK_UNIPHY_SGMIIPLUS,
					   SPEED_2500);
	if (ret)
		goto restore;
	pr_info("force_sgmiiplus: uniphy%d set to SGMII+ 2.5G\n",
		UNIPHY_INDEX);

	msleep(1000);
	ret = ssdk_mac_sw_sync_work_start(DEV_ID);
	if (ret) {
		pr_err("force_sgmiiplus: failed to restart sync worker: %d\n", ret);
		goto restore;
	}
	pr_info("force_sgmiiplus: loop restarted (port %d excluded, interface mode forced)\n",
		SSDK_PORT_ID);

	ret = force_sgmiiplus_sync_host_link(true);
	if (ret) {
		pr_err("force_sgmiiplus: initial host link synchronization failed: %d\n",
		       ret);
		goto restore;
	}

	link_monitor_task = kthread_run(force_sgmiiplus_link_monitor, NULL,
					"sgmiiplus-link");
	if (IS_ERR(link_monitor_task)) {
		ret = PTR_ERR(link_monitor_task);
		link_monitor_task = NULL;
		pr_err("force_sgmiiplus: failed to start link monitor: %d\n",
		       ret);
		goto restore;
	}

	pr_info("force_sgmiiplus: PCS link monitor started; PON RX_LOS ignored\n");

	return 0;

restore:
	if (link_monitor_task) {
		kthread_stop(link_monitor_task);
		link_monitor_task = NULL;
	}
	/*
	 * The worker was restarted before initial link synchronization. Stop it
	 * again before rollback so it cannot observe or rewrite half-restored
	 * interface and mux state.
	 */
	restore_ret = ssdk_mac_sw_sync_work_stop(DEV_ID);
	if (restore_ret)
		pr_err("force_sgmiiplus: failed to stop worker during rollback: %d\n",
		       restore_ret);
	restore_ret = force_sgmiiplus_restore_interface();
	force_sgmiiplus_restore_cache();
	port_bmp_set(DEV_ID, orig_port_bmp);
	if (ssdk_mac_sw_sync_work_start(DEV_ID))
		pr_err("force_sgmiiplus: failed to restart worker during rollback\n");
	if (!ret)
		ret = restore_ret;
	return ret;
}

static void __exit force_sgmiiplus_exit(void)
{
	int ret;

	if (link_monitor_task) {
		kthread_stop(link_monitor_task);
		link_monitor_task = NULL;
		pr_info("force_sgmiiplus: PCS link monitor stopped\n");
	}

	ret = ssdk_mac_sw_sync_work_stop(DEV_ID);
	if (ret)
		pr_err("force_sgmiiplus: failed to stop worker during unload: %d\n",
		       ret);

	force_sgmiiplus_restore_interface();
	force_sgmiiplus_restore_cache();
	port_bmp_set(DEV_ID, orig_port_bmp);

	ret = ssdk_mac_sw_sync_work_start(DEV_ID);
	if (ret)
		pr_err("force_sgmiiplus: failed to restart worker during unload: %d\n",
		       ret);

	pr_info("force_sgmiiplus: reverted port_mode=0x%x mac_mode=0x%x force=%u bitmap=0x%x\n",
		orig_port_iface_mode, orig_mac_mode,
		orig_force_interface_mode ? 1 : 0, orig_port_bmp);
}

module_init(force_sgmiiplus_init);
module_exit(force_sgmiiplus_exit);
