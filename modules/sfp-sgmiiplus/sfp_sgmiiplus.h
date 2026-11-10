/* Shared SGMII+ implementation for the two existing port-specific modules.
 * Default mode leaves SFP recovery to the stock driver. hold=1 keeps SGMII+
 * across SFP events; only one module may own the shared QCA SFP callback.
 * Private offsets and lock paths are checked against UniFi OS 6.0.17.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>
#include <linux/delay.h>
#include <linux/kmod.h>
#include <linux/phy.h>
#include <linux/atomic.h>
#include <linux/string.h>
#include <linux/rtnetlink.h>
#include <linux/workqueue.h>
#include <linux/mutex.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Ozark Connect");
MODULE_DESCRIPTION("Force UCG-Fiber / UXG-Fiber " SGMII_IFACE " to SGMII+ 2.5G");
#define SGMIIPLUS_VERSION "5"
MODULE_VERSION(SGMIIPLUS_VERSION);

/*
 * The vendor kernel strips modinfo (CONFIG_MODULE_STRIPPED), so MODULE_VERSION
 * leaves no /sys/module/<module>/version there. Parameters are kept; this
 * read-only one names the loaded build.
 */
static int param_get_version(char *buf, const struct kernel_param *kp)
{
	return sprintf(buf, "%s\n", SGMIIPLUS_VERSION);
}

static const struct kernel_param_ops version_ops = {
	.get = param_get_version,
};
module_param_cb(version, &version_ops, NULL, 0444);
MODULE_PARM_DESC(version, "Module build version");

static bool hold;
module_param(hold, bool, 0444);
MODULE_PARM_DESC(hold, "Keep SGMII+ across SFP events (default off; one hold port at a time)");

/* Exported by qca-ssdk.ko */
extern int ssdk_mac_sw_sync_work_stop(unsigned int dev_id);
extern int ssdk_mac_sw_sync_work_start(unsigned int dev_id);

/* Local symbols resolved via kallsyms */
typedef int (*uniphy_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, int mode);
typedef int (*port_iface_mode_set_fn)(unsigned int dev_id, unsigned long port_id, int mode);
typedef int (*port_iface_mode_get_fn)(unsigned int dev_id, unsigned int port_id, int *mode);
typedef int (*dt_global_set_mac_mode_fn)(unsigned long dev_id, int uniphy_index, unsigned int mode);
typedef unsigned int (*dt_global_get_mac_mode_fn)(unsigned int dev_id, unsigned int uniphy_index);
typedef unsigned int (*port_bmp_get_fn)(unsigned int dev_id);
typedef void (*port_bmp_set_fn)(unsigned int dev_id, unsigned int bmp);
typedef unsigned long (*priv_data_get_fn)(unsigned int dev_id);
typedef void (*phy_event_fn)(unsigned char port);
typedef void (*link_notify_fn)(unsigned char port, unsigned char link,
			       unsigned char speed, unsigned char duplex);
typedef int (*port_phydev_get_fn)(unsigned int dev_id, unsigned int port_id,
				  struct phy_device **phydev);
typedef unsigned int (*phydev_to_port_fn)(unsigned int dev_id, struct phy_device *phydev);
typedef int (*uniphy_io6_get_fn)(unsigned int dev_id, unsigned int uniphy_index, u32 *value);
typedef void (*port_status_init_fn)(unsigned int dev_id, unsigned int port_id);
typedef int (*config_aneg_fn)(struct phy_device *phydev);
typedef int (*port_feature_get_fn)(unsigned int dev_id, unsigned int port_id, unsigned int feature);
typedef int (*port_feature_update_fn)(unsigned int dev_id, unsigned int port_id, unsigned int feature);
typedef int (*force_speed_mode_set_fn)(unsigned int dev_id, unsigned int uniphy_index, unsigned int value);
typedef int (*port_mac_enable_fn)(unsigned int dev_id, unsigned int port_id, int enable);
typedef int (*port_speed_fn)(unsigned int dev_id, unsigned int port_id, unsigned int value);
typedef void (*mib_pause_fn)(unsigned long priv);
typedef int (*mib_resume_fn)(unsigned long priv);
typedef int (*port_reset_fn)(unsigned int dev_id, unsigned int port_id);

static uniphy_mode_set_fn uniphy_mode_set;
static port_iface_mode_set_fn port_iface_mode_set;
static port_iface_mode_get_fn port_iface_mode_get;
static dt_global_set_mac_mode_fn dt_global_set_mac_mode;
static dt_global_get_mac_mode_fn dt_global_get_mac_mode;
static port_bmp_get_fn port_bmp_get;
static port_bmp_set_fn port_bmp_set;
static port_phydev_get_fn port_phydev_get;
static phydev_to_port_fn phydev_to_port;
static uniphy_io6_get_fn uniphy_io6_get;
static port_status_init_fn port_status_init;
static config_aneg_fn sfp_config_aneg;
static port_feature_get_fn port_feature_get;
static port_feature_update_fn port_feature_set;
static port_feature_update_fn port_feature_clear;
static force_speed_mode_set_fn force_speed_mode_set;
static port_mac_enable_fn txmac_status_set;
static port_mac_enable_fn rxmac_status_set;
static port_mac_enable_fn bridge_txmac_set;
static port_mac_enable_fn gcc_uniphy_clock_status_set;
static port_speed_fn gcc_port_speed_clock_set;
static port_speed_fn mac_speed_set;
static port_speed_fn mac_duplex_set;
static port_reset_fn uniphy_port_adapter_reset;
static mib_pause_fn mib_work_pause;
static mib_resume_fn mib_work_resume;
static void *mib_work_task;	/* qca_phy_mib_work_task, to check the work at priv+0x2a0 */
static void *sync_work_task;	/* qca_mac_sw_sync_work_task, to check the work at priv+0x9b0 */

#define SSDK_UNIPHY_SGMIIPLUS 0x0c
#define SSDK_MIN_PORT 5
#define SSDK_MAX_PORT 6		/* eth5 = port 6 also uses the "QCA SFP" driver */
#define DEV_ID 0
#define PORT_MODE_SGMIIPLUS 6
#define PORT_MODE_SGMII_BASET 4		/* stock 1G, autoneg off (SFP auto-detect) */
#define PORT_MODE_SGMII_FIBER 0x0e	/* stock 1G, autoneg on (boot default) */
#define PHY_F_FORCE 0x40		/* SSDK port feature: forced speed */
#define MAC_MODE_SGMII_CH0 0x0f		/* uniphy mac_mode with PORT_MODE_SGMII_BASET */
#define MAC_MODE_SGMII_FIBER 0x14	/* uniphy mac_mode with PORT_MODE_SGMII_FIBER */
#define SFP_DRIVER_NAME "QCA SFP"
#define UNIPHY_CH0_LINK_BIT 7	/* newaddedfromhere_ch0_link in uniphy_channel0_input_output_6 */

#define CACHE_SPEED_2500   2500
#define CACHE_DUPLEX_FULL  1
#define LINK_NOTIFY_SPEED_2500 3

#define FAL_SPEED_2500 2500
#define FAL_FULL_DUPLEX 1

#define LINK_CACHE_BASE   0x650
#define SPEED_CACHE_BASE  0x690
#define DUPLEX_CACHE_BASE 0x6d0
#define PORT_STRIDE       4

/*
 * qca-ssdk private data (ssdk_phy_priv_data_get), 6.0.17:
 * adpt_hppe_port_interface_mode_apply takes the mutex at +0x990 around every
 * interface mode apply (which resets the uniphy); qca_mac_sw_sync_work_task
 * (work at +0x9b0) takes the same mutex. qca_phy_mib_work_task (work at
 * +0x2a0) reads the MAC MIB counters of all ports.
 */
#define PRIV_CFG_MUTEX    0x990
#define PRIV_SYNC_WORK    0x9b0
#define PRIV_MIB_WORK     0x2a0

/*
 * Layout of the vendor kernel, read from qca-nss-dp.ko and qca-ssdk.ko of
 * UniFi OS 6.0.17 (qca_phy_ethtool_set_link_ksettings, sfp_phy_config_aneg,
 * sfp_read_status). The wrapper below dereferences phydev and phydev->drv,
 * so a build against a tree with a different layout must fail.
 */
static inline void layout_checks(void)
{
	BUILD_BUG_ON(offsetof(struct phy_device, mdio.addr) != 0x318);
	BUILD_BUG_ON(offsetof(struct phy_device, drv) != 0x338);
	BUILD_BUG_ON(offsetof(struct phy_device, speed) != 0x378);
	BUILD_BUG_ON(offsetof(struct phy_device, duplex) != 0x37c);
	BUILD_BUG_ON(offsetof(struct phy_device, advertising) != 0x398);
	BUILD_BUG_ON(offsetof(struct phy_device, lock) != 0x430);
	BUILD_BUG_ON(offsetof(struct phy_driver, name) != 0x98);
	BUILD_BUG_ON(offsetof(struct phy_driver, config_aneg) != 0xf0);
}

static unsigned int orig_port_bmp;
static int orig_port_mode;
static unsigned int orig_mac_mode;
static int orig_force;
static unsigned long priv_addr;
static unsigned int orig_speed;
static unsigned int orig_duplex;

/* config_aneg guard */
static struct phy_device *guard_phydev;
static struct phy_driver *guard_drv;
static config_aneg_fn orig_config_aneg;
static int guard_active;
static atomic_t guard_inflight = ATOMIC_INIT(0);
static atomic_t guard_suppressed = ATOMIC_INIT(0);

static int param_get_suppressed(char *buf, const struct kernel_param *kp)
{
	return sprintf(buf, "%d\n", atomic_read(&guard_suppressed));
}

static const struct kernel_param_ops suppressed_ops = {
	.get = param_get_suppressed,
};
module_param_cb(suppressed, &suppressed_ops, NULL, 0444);
MODULE_PARM_DESC(suppressed, "config_aneg requests ignored for " SGMII_IFACE);

/* qca-ssdk config mutex (priv+0x990), set once the layout is checked */
static struct mutex *cfg_mutex;

/*
 * Live SerDes link of the target uniphy channel 0, independent of the frozen link cache.
 * Read under the config mutex, so it never touches the target while it is being
 * reset (by us or by a stock mode apply).
 */
static int param_get_pcs_link(char *buf, const struct kernel_param *kp)
{
	struct mutex *m = READ_ONCE(cfg_mutex);
	u32 v = 0;
	int ret;

	if (!m || !uniphy_io6_get || mutex_lock_killable(m))
		return sprintf(buf, "-1\n");
	ret = uniphy_io6_get(DEV_ID, UNIPHY_INDEX, &v);
	mutex_unlock(m);
	if (ret != 0)
		return sprintf(buf, "-1\n");
	return sprintf(buf, "%u\n", (v >> UNIPHY_CH0_LINK_BIT) & 1);
}

static const struct kernel_param_ops pcs_link_ops = {
	.get = param_get_pcs_link,
};
module_param_cb(pcs_link, &pcs_link_ops, NULL, 0444);
MODULE_PARM_DESC(pcs_link, "Target SerDes link (1 up, 0 down, -1 unreadable)");

static int guarded_config_aneg(struct phy_device *phydev)
{
	int ret;

	atomic_inc(&guard_inflight);
	/* The caller read our callback before entering here. Pair with the
	 * write barrier before publishing that callback, also on the other port where
	 * the guard_active acquire below is deliberately skipped. */
	smp_rmb();
	if (phydev == READ_ONCE(guard_phydev) && smp_load_acquire(&guard_active)) {
		atomic_inc(&guard_suppressed);
		pr_info_ratelimited(SGMII_LOG_PREFIX ": SGMII+ kept, config_aneg on port %d ignored (autoneg %u, speed %d)\n",
				    SSDK_PORT_ID, phydev->autoneg, phydev->speed);
		ret = 0;
	} else {
		ret = READ_ONCE(orig_config_aneg)(phydev);
	}
	atomic_dec(&guard_inflight);
	return ret;
}

/*
 * Wait for config_aneg calls that read the callback pointer before it was
 * changed. Both callers hold a lock across reading the pointer and the call:
 * phylib (phy_start_aneg) holds phydev->lock, and the "QCA SFP" ethtool path
 * in qca-nss-dp (qca_phy_ethtool_set_link_ksettings) runs under RTNL. Taking
 * each lock once waits for them.
 */
static void flush_config_aneg_callers(void)
{
	struct phy_device *pd;
	unsigned int port;

	rtnl_lock();
	rtnl_unlock();
	for (port = SSDK_MIN_PORT; port <= SSDK_MAX_PORT; port++) {
		pd = NULL;
		if (port_phydev_get(DEV_ID, port, &pd) == 0 && pd &&
		    pd->drv == guard_drv) {
			mutex_lock(&pd->lock);
			mutex_unlock(&pd->lock);
		}
	}
}

/*
 * The driver object is shared by both SFP ports (eth5 and eth6). Install only
 * if it is the expected driver and nobody else replaced the callback.
 */
static int guard_install(void)
{
	struct phy_device *phydev = NULL;
	struct phy_driver *drv;

	if (port_phydev_get(DEV_ID, SSDK_PORT_ID, &phydev) != 0 || !phydev) {
		pr_err(SGMII_LOG_PREFIX ": no phy device for port %d\n", SSDK_PORT_ID);
		return -ENODEV;
	}
	if (phydev_to_port(DEV_ID, phydev) != SSDK_PORT_ID) {
		pr_err(SGMII_LOG_PREFIX ": phy device does not map back to port %d\n", SSDK_PORT_ID);
		return -ENODEV;
	}
	drv = phydev->drv;
	if (!drv || !drv->name || strcmp(drv->name, SFP_DRIVER_NAME) != 0) {
		pr_err(SGMII_LOG_PREFIX ": port %d is not driven by \"%s\"\n",
		       SSDK_PORT_ID, SFP_DRIVER_NAME);
		return -ENODEV;
	}
	if (drv->config_aneg != sfp_config_aneg) {
		pr_err(SGMII_LOG_PREFIX ": config_aneg is not sfp_phy_config_aneg (%ps), not hooking\n",
		       drv->config_aneg);
		return -EBUSY;
	}

	WRITE_ONCE(guard_phydev, phydev);
	guard_drv = drv;
	WRITE_ONCE(orig_config_aneg, drv->config_aneg);
	smp_store_release(&guard_active, 1);
	/* Publish every wrapper dependency before the callback becomes callable.
	 * guarded_config_aneg pairs this with smp_rmb(), including the other-port path. */
	smp_wmb();
	if (cmpxchg(&drv->config_aneg, sfp_config_aneg, guarded_config_aneg) != sfp_config_aneg) {
		smp_store_release(&guard_active, 0);
		guard_drv = NULL;
		WRITE_ONCE(guard_phydev, NULL);
		pr_err(SGMII_LOG_PREFIX ": another callback owner won the hold-mode race\n");
		return -EBUSY;
	}

	/* Called with RTNL and this PHY lock held: old target callbacks have
	 * finished. Other-port callers use the ordered wrapper dependencies. */
	pr_info(SGMII_LOG_PREFIX ": config_aneg guard installed (ordered publication) for port %d\n", SSDK_PORT_ID);
	return 0;
}

static void guard_remove(void)
{
	if (!guard_drv)
		return;

	smp_store_release(&guard_active, 0);
	if (cmpxchg(&guard_drv->config_aneg, guarded_config_aneg,
		    orig_config_aneg) != guarded_config_aneg)
		pr_warn(SGMII_LOG_PREFIX ": config_aneg was replaced by someone else, left as is\n");
	smp_mb();

	/* A caller may have read the wrapper pointer but not entered it yet */
	flush_config_aneg_callers();

	/* Calls that entered the wrapper (the other SFP may sleep 500 ms in there) */
	while (atomic_read(&guard_inflight))
		msleep(10);
	guard_drv = NULL;
	WRITE_ONCE(guard_phydev, NULL);
}

/*
 * adpt_hppe_uniphy_mode_set() resets the target uniphy for more than 100 ms
 * and gates its port clocks. qca-ssdk only does that under its config mutex,
 * and a CPU access to the uniphy or the target MAC in that window can end in
 * an AHB timeout, which resets the whole SoC (seen once on a live module
 * swap). So, like the vendor, stop the MAC sync loop, pause the MIB counter
 * work, take the config mutex, and take the port down before switching.
 * Statistics read through ethtool -S do not take any lock and cannot be
 * excluded here; doing this at boot, before traffic, keeps that window small.
 */
static bool mib_paused;

static bool priv_work_is(unsigned long off, void *fn)
{
	struct delayed_work *dw = (struct delayed_work *)(priv_addr + off);

	return fn && dw->work.func == (work_func_t)fn;
}

/*
 * The MIB work only has its function set once qca_phy_mib_work_start ran,
 * and it re-queues itself, so pause and resume it whenever it is set up
 * (work_busy() is only a snapshot). Called with the layout already checked.
 *
 * RTNL serializes our worker pause/resume across both modules. No RTNL-taking
 * worker callback was found in the checked 6.0.17 paths. Cancel them before
 * taking a PHY or config lock, since their work can require those locks.
 * The target PHY lock also excludes phylib callbacks in default mode, where
 * no config_aneg hook is installed. Additional RTNL-taking notifier callbacks
 * outside the checked firmware would invalidate this lock order. */
static struct phy_device *transition_phydev;

static int transition_begin(void)
{
	int ret;

	rtnl_lock();
	transition_phydev = NULL;
	ret = port_phydev_get(DEV_ID, SSDK_PORT_ID, &transition_phydev);
	if (ret || !transition_phydev ||
	    phydev_to_port(DEV_ID, transition_phydev) != SSDK_PORT_ID ||
	    !transition_phydev->drv || !transition_phydev->drv->name ||
	    strcmp(transition_phydev->drv->name, SFP_DRIVER_NAME)) {
		pr_err(SGMII_LOG_PREFIX ": target port %d has no expected SFP PHY\n", SSDK_PORT_ID);
		rtnl_unlock();
		return -ENODEV;
	}
	ssdk_mac_sw_sync_work_stop(DEV_ID);
	mib_paused = priv_work_is(PRIV_MIB_WORK, mib_work_task);
	if (mib_paused)
		mib_work_pause(priv_addr);
	mutex_lock(&transition_phydev->lock);
	mutex_lock(cfg_mutex);
	return 0;
}

static void transition_end(void)
{
	mutex_unlock(cfg_mutex);
	mutex_unlock(&transition_phydev->lock);
	if (mib_paused)
		mib_work_resume(priv_addr);
	ssdk_mac_sw_sync_work_start(DEV_ID);
	rtnl_unlock();
}

static void restore_port_bit(void)
{
	unsigned int bit = 1u << SSDK_PORT_ID;

	port_bmp_set(DEV_ID, (port_bmp_get(DEV_ID) & ~bit) | (orig_port_bmp & bit));
}

/*
 * Vendor link-down order (qca_hppe_mac_sw_sync_task): bridge TX off, 10 ms,
 * RX and TX MAC off. The port clock is left to the mode set, which gates and
 * ungates it itself; the clocks are reference counted, so an extra disable
 * here would unbalance them.
 */
static void port_down(void)
{
	bridge_txmac_set(DEV_ID, SSDK_PORT_ID, 0);
	usleep_range(10000, 11000);
	rxmac_status_set(DEV_ID, SSDK_PORT_ID, 0);
	txmac_status_set(DEV_ID, SSDK_PORT_ID, 0);
}

/* Vendor link-up order and delays, for 2500 full duplex */
static void port_up_2500(void)
{
	gcc_uniphy_clock_status_set(DEV_ID, SSDK_PORT_ID, 0);
	gcc_port_speed_clock_set(DEV_ID, SSDK_PORT_ID, FAL_SPEED_2500);
	msleep(20);	/* the loop waits 2 x 10 ms around the MAC speed change */
	mac_speed_set(DEV_ID, SSDK_PORT_ID, FAL_SPEED_2500);
	mac_duplex_set(DEV_ID, SSDK_PORT_ID, FAL_FULL_DUPLEX);
	gcc_uniphy_clock_status_set(DEV_ID, SSDK_PORT_ID, 1);
	uniphy_port_adapter_reset(DEV_ID, SSDK_PORT_ID);
	txmac_status_set(DEV_ID, SSDK_PORT_ID, 1);
	rxmac_status_set(DEV_ID, SSDK_PORT_ID, 1);
	bridge_txmac_set(DEV_ID, SSDK_PORT_ID, 1);
}

static int __init force_sgmiiplus_init(void)
{
	int ret;
	unsigned int bmp;

	layout_checks();

	uniphy_mode_set = (uniphy_mode_set_fn)kallsyms_lookup_name(
		"adpt_hppe_uniphy_mode_set");
	port_iface_mode_set = (port_iface_mode_set_fn)kallsyms_lookup_name(
		"_adpt_hppe_port_interface_mode_set");
	port_iface_mode_get = (port_iface_mode_get_fn)kallsyms_lookup_name(
		"adpt_hppe_port_interface_mode_get");
	dt_global_set_mac_mode = (dt_global_set_mac_mode_fn)kallsyms_lookup_name(
		"ssdk_dt_global_set_mac_mode");
	dt_global_get_mac_mode = (dt_global_get_mac_mode_fn)kallsyms_lookup_name(
		"ssdk_dt_global_get_mac_mode");
	port_bmp_get = (port_bmp_get_fn)kallsyms_lookup_name(
		"qca_ssdk_port_bmp_get");
	port_bmp_set = (port_bmp_set_fn)kallsyms_lookup_name(
		"qca_ssdk_port_bmp_set");
	port_phydev_get = (port_phydev_get_fn)kallsyms_lookup_name(
		"hsl_port_phydev_get");
	phydev_to_port = (phydev_to_port_fn)kallsyms_lookup_name(
		"qca_ssdk_phydev_to_port");
	uniphy_io6_get = (uniphy_io6_get_fn)kallsyms_lookup_name(
		"hppe_uniphy_channel0_input_output_6_get");
	port_status_init = (port_status_init_fn)kallsyms_lookup_name(
		"qca_mac_port_status_init");
	sfp_config_aneg = (config_aneg_fn)kallsyms_lookup_name(
		"sfp_phy_config_aneg");
	port_feature_get = (port_feature_get_fn)kallsyms_lookup_name(
		"hsl_port_feature_get");
	port_feature_set = (port_feature_update_fn)kallsyms_lookup_name(
		"hsl_port_feature_set");
	port_feature_clear = (port_feature_update_fn)kallsyms_lookup_name(
		"hsl_port_feature_clear");
	force_speed_mode_set = (force_speed_mode_set_fn)kallsyms_lookup_name(
		"hppe_uniphy_channel0_force_speed_mode_set");
	txmac_status_set = (port_mac_enable_fn)kallsyms_lookup_name(
		"adpt_hppe_port_txmac_status_set");
	rxmac_status_set = (port_mac_enable_fn)kallsyms_lookup_name(
		"adpt_hppe_port_rxmac_status_set");
	bridge_txmac_set = (port_mac_enable_fn)kallsyms_lookup_name(
		"adpt_hppe_port_bridge_txmac_set");
	gcc_uniphy_clock_status_set = (port_mac_enable_fn)kallsyms_lookup_name(
		"adpt_hppe_gcc_uniphy_clock_status_set");
	gcc_port_speed_clock_set = (port_speed_fn)kallsyms_lookup_name(
		"adpt_hppe_gcc_port_speed_clock_set");
	mac_speed_set = (port_speed_fn)kallsyms_lookup_name(
		"adpt_hppe_port_mac_speed_set");
	mac_duplex_set = (port_speed_fn)kallsyms_lookup_name(
		"adpt_hppe_port_mac_duplex_set");
	uniphy_port_adapter_reset = (port_reset_fn)kallsyms_lookup_name(
		"adpt_hppe_uniphy_port_adapter_reset");
	mib_work_pause = (mib_pause_fn)kallsyms_lookup_name("qca_phy_mib_work_pause");
	mib_work_resume = (mib_resume_fn)kallsyms_lookup_name("qca_phy_mib_work_resume");
	mib_work_task = (void *)kallsyms_lookup_name("qca_phy_mib_work_task");
	sync_work_task = (void *)kallsyms_lookup_name("qca_mac_sw_sync_work_task");
	{
		priv_data_get_fn get_priv = (priv_data_get_fn)
			kallsyms_lookup_name("ssdk_phy_priv_data_get");

		if (get_priv)
			priv_addr = get_priv(DEV_ID);
	}

	if (!uniphy_mode_set || !port_iface_mode_set || !port_iface_mode_get ||
	    !dt_global_set_mac_mode || !dt_global_get_mac_mode ||
	    !port_bmp_get || !port_bmp_set || !port_phydev_get ||
	    !phydev_to_port || !uniphy_io6_get || !port_status_init ||
	    (hold && !sfp_config_aneg) || !port_feature_get || !port_feature_set ||
	    !port_feature_clear || !force_speed_mode_set ||
	    !txmac_status_set || !rxmac_status_set || !bridge_txmac_set ||
	    !gcc_uniphy_clock_status_set || !gcc_port_speed_clock_set ||
	    !mac_speed_set || !mac_duplex_set || !mib_work_pause ||
	    !mib_work_resume || !priv_addr || !uniphy_port_adapter_reset) {
		pr_err(SGMII_LOG_PREFIX ": kallsyms lookup failed\n");
		uniphy_mode_set = NULL;
		uniphy_io6_get = NULL;
		return -ENOENT;
	}

	pr_info(SGMII_LOG_PREFIX ": resolved all symbols\n");

	/* The config mutex sits next to the sync work it protects; check that
	 * work's function before relying on the offset */
	if (!priv_work_is(PRIV_SYNC_WORK, sync_work_task)) {
		pr_err(SGMII_LOG_PREFIX ": qca-ssdk private data layout not as expected, not taking over\n");
		uniphy_mode_set = NULL;
		uniphy_io6_get = NULL;
		return -ENODEV;
	}
	{
		struct delayed_work *mib = (struct delayed_work *)(priv_addr + PRIV_MIB_WORK);

		/* Not started (no function) is fine; anything else is unknown */
		if (mib->work.func && !priv_work_is(PRIV_MIB_WORK, mib_work_task)) {
			pr_err(SGMII_LOG_PREFIX ": MIB work not as expected, not taking over\n");
			uniphy_mode_set = NULL;
			uniphy_io6_get = NULL;
			return -ENODEV;
		}
	}
	WRITE_ONCE(cfg_mutex, (struct mutex *)(priv_addr + PRIV_CFG_MUTEX));

	ret = transition_begin();
	if (ret) {
		uniphy_mode_set = NULL;
		return ret;
	}

	/* RTNL and the target PHY lock exclude both stock config_aneg paths;
	 * sync work is stopped and cfg_mutex is held. Snapshot coherently, not
	 * while auto-detect can still change its mode or forced-speed flag.
	 * The 6.0.17 getters below (and their hsl helpers) only read memory;
	 * they do not acquire cfg_mutex recursively. */
	ret = port_iface_mode_get(DEV_ID, SSDK_PORT_ID, &orig_port_mode);
	if (ret != 0) {
		pr_err(SGMII_LOG_PREFIX ": reading port %d interface mode failed: %d\n",
		       SSDK_PORT_ID, ret);
		ret = -EIO;
		goto abort_takeover;
	}
	orig_mac_mode = dt_global_get_mac_mode(DEV_ID, UNIPHY_INDEX);
	pr_info(SGMII_LOG_PREFIX ": found port %d mode 0x%x, uniphy%d mac_mode 0x%x\n",
		SSDK_PORT_ID, orig_port_mode, UNIPHY_INDEX, orig_mac_mode);
	if (!(orig_port_mode == PORT_MODE_SGMII_FIBER && orig_mac_mode == MAC_MODE_SGMII_FIBER) &&
	    !(orig_port_mode == PORT_MODE_SGMII_BASET && orig_mac_mode == MAC_MODE_SGMII_CH0)) {
		pr_err(SGMII_LOG_PREFIX ": port %d mode 0x%x / mac_mode 0x%x is not stock SGMII 1G, not taking over\n",
		       SSDK_PORT_ID, orig_port_mode, orig_mac_mode);
		ret = -EBUSY;
		goto abort_takeover;
	}
	orig_force = port_feature_get(DEV_ID, SSDK_PORT_ID, PHY_F_FORCE) ? 1 : 0;

	if (hold) {
		ret = guard_install();
		if (ret)
			goto abort_takeover;
	}
	pr_info(SGMII_LOG_PREFIX ": port %d mode: %s\n", SSDK_PORT_ID, hold ? "hold" : "default");

	orig_port_bmp = port_bmp_get(DEV_ID);
	bmp = orig_port_bmp & ~(1u << SSDK_PORT_ID);
	port_bmp_set(DEV_ID, bmp);
	pr_info(SGMII_LOG_PREFIX ": port bitmap 0x%x -> 0x%x (port %d excluded)\n",
		orig_port_bmp, bmp, SSDK_PORT_ID);

	port_down();

	/*
	 * After the SFP auto-detect's 1000/AN-off step the port carries
	 * PHY_F_FORCE and the target uniphy channel 0 runs in forced-speed mode. The
	 * SGMII+ mode set does not reset that; left on, the SerDes
	 * links at 2.5G but no data passes. Run SGMII+ unforced, like after boot.
	 */
	if (orig_force) {
		port_feature_clear(DEV_ID, SSDK_PORT_ID, PHY_F_FORCE);
		pr_info(SGMII_LOG_PREFIX ": cleared forced-speed mode left by 1G autoneg-off\n");
	}
	force_speed_mode_set(DEV_ID, UNIPHY_INDEX, 0);

	ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);
	if (ret != 0) {
		pr_err(SGMII_LOG_PREFIX ": uniphy_mode_set failed: %d\n", ret);
		if (orig_force)
			port_feature_set(DEV_ID, SSDK_PORT_ID, PHY_F_FORCE);
		if (uniphy_mode_set(DEV_ID, UNIPHY_INDEX, orig_mac_mode))
			pr_err(SGMII_LOG_PREFIX ": switching uniphy%d back failed too\n", UNIPHY_INDEX);
		/* port is down; let the loop bring it up again from scratch */
		port_status_init(DEV_ID, SSDK_PORT_ID);
		restore_port_bit();
		goto abort_takeover;
	}
	pr_info(SGMII_LOG_PREFIX ": uniphy%d set to SGMII+ 2.5G\n", UNIPHY_INDEX);

	port_iface_mode_set(DEV_ID, SSDK_PORT_ID, PORT_MODE_SGMIIPLUS);
	dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, SSDK_UNIPHY_SGMIIPLUS);

	/*
	 * Bring the port up the way the loop's link-up branch does, for 2500
	 * full duplex. The target port is excluded from the loop from now on.
	 */
	port_up_2500();

	/* Update SSDK SFP PHY speed cache so ethtool/sysfs/UDAPI report 2500 */
	{
		phy_event_fn send_phy_event;
		link_notify_fn notify;
		unsigned int *sp, *dp;

		{
			sp = (unsigned int *)(priv_addr + SPEED_CACHE_BASE +
					     (SSDK_PORT_ID - 1) * PORT_STRIDE);
			dp = (unsigned int *)(priv_addr + DUPLEX_CACHE_BASE +
					     (SSDK_PORT_ID - 1) * PORT_STRIDE);
			orig_speed = *sp;
			orig_duplex = *dp;
			*sp = CACHE_SPEED_2500;
			*dp = CACHE_DUPLEX_FULL;
			/* the loop no longer maintains this port; report it up */
			*(unsigned int *)(priv_addr + LINK_CACHE_BASE +
					  (SSDK_PORT_ID - 1) * PORT_STRIDE) = 1;
			pr_info(SGMII_LOG_PREFIX ": speed cache %u -> %u\n",
				orig_speed, CACHE_SPEED_2500);
		}

		transition_end();
		pr_info(SGMII_LOG_PREFIX ": loop restarted (port %d excluded)\n", SSDK_PORT_ID);

		notify = (link_notify_fn)
			kallsyms_lookup_name("ssdk_port_link_notify");
		if (notify)
			notify(SSDK_PORT_ID, 1, LINK_NOTIFY_SPEED_2500, 1);

		send_phy_event = (phy_event_fn)
			kallsyms_lookup_name("ubnt_send_phy_event");
		if (send_phy_event)
			send_phy_event(SSDK_PORT_ID);

		/* Trigger RTM_NEWLINK so UDAPI re-reads ethtool.
		 * Delayed 2s for PHY state machine to copy cache into
		 * phydev->speed. UMH_NO_WAIT so module init returns
		 * immediately — doesn't block the dsmp event loop. */
		{
			static char *argv[] = {
				"/bin/sh", "-c",
				"sleep 2 && ip link set " SGMII_IFACE " alias x && ip link set " SGMII_IFACE " alias ''",
				NULL
			};
			static char *envp[] = { "PATH=/sbin:/bin", NULL };

			call_usermodehelper(argv[0], argv, envp,
					   UMH_NO_WAIT);
		}
		pr_info(SGMII_LOG_PREFIX ": speed reporting updated\n");
	}

	return 0;

abort_takeover:
	/* Snapshot failures have not changed hardware or the port bitmap. A
	 * failed mode set has restored them above. Release cfg_mutex before
	 * draining callback callers, which may need that same mutex. Target
	 * requests can go straight to stock once the transition locks release. */
	smp_store_release(&guard_active, 0);
	transition_end();
	guard_remove();
	if (atomic_read(&guard_suppressed))
		pr_warn(SGMII_LOG_PREFIX ": takeover aborted after ignoring %d config_aneg request(s); stock link settings may need reapplying\n",
			atomic_read(&guard_suppressed));
	uniphy_mode_set = NULL;
	return ret;
}

static void __exit force_sgmiiplus_exit(void)
{
	unsigned int *sp, *dp;
	unsigned int current_mac_mode;
	int ret, current_port_mode;
	bool owns_mode;

	if (!uniphy_mode_set)
		return;

	/* Keep the hold guard until the revert has finished. RTNL and the
	 * target PHY lock exclude both stock config_aneg paths while reverting. */
	ret = transition_begin();
	if (ret) {
		pr_err(SGMII_LOG_PREFIX ": cannot enter revert transaction (%d); hardware, polling and caches were not restored, planned reboot required\n", ret);
		guard_remove();
		return;
	}

	/* Default mode permits newer stock decisions. Do not overwrite one
	 * with the load-time snapshot, or reset an uniphy no longer owned by us.
	 * On a failed read, leave the hardware untouched for the same reason. */
	ret = port_iface_mode_get(DEV_ID, SSDK_PORT_ID, &current_port_mode);
	current_mac_mode = dt_global_get_mac_mode(DEV_ID, UNIPHY_INDEX);
	owns_mode = !ret && current_port_mode == PORT_MODE_SGMIIPLUS &&
		current_mac_mode == SSDK_UNIPHY_SGMIIPLUS;
	if (owns_mode) {
		port_down();
		/* The stock mode set reads this feature to restore forced speed. */
		if (orig_force)
			port_feature_set(DEV_ID, SSDK_PORT_ID, PHY_F_FORCE);
		else
			port_feature_clear(DEV_ID, SSDK_PORT_ID, PHY_F_FORCE);
		ret = uniphy_mode_set(DEV_ID, UNIPHY_INDEX, orig_mac_mode);
		port_iface_mode_set(DEV_ID, SSDK_PORT_ID, orig_port_mode);
		dt_global_set_mac_mode(DEV_ID, UNIPHY_INDEX, orig_mac_mode);
	} else {
		pr_warn(SGMII_LOG_PREFIX ": target mode changed or unreadable; preserving current hardware settings on exit\n");
	}

	sp = (unsigned int *)(priv_addr + SPEED_CACHE_BASE + (SSDK_PORT_ID - 1) * PORT_STRIDE);
	dp = (unsigned int *)(priv_addr + DUPLEX_CACHE_BASE + (SSDK_PORT_ID - 1) * PORT_STRIDE);
	*sp = orig_speed;
	*dp = orig_duplex;
	pr_info(SGMII_LOG_PREFIX ": speed cache restored to %u\n", orig_speed);

	/* Let stock polling rediscover link and speed from hardware. */
	port_status_init(DEV_ID, SSDK_PORT_ID);
	restore_port_bit();

	/* Locks still exclude target callers. Once released, requests should
	 * reach stock immediately, including before the wrapper is removed. */
	smp_store_release(&guard_active, 0);
	transition_end();
	if (owns_mode && ret)
		pr_err(SGMII_LOG_PREFIX ": switching uniphy%d back to mac_mode 0x%x failed (%d); target port may stay down until a reboot or an SFP change\n",
		       UNIPHY_INDEX, orig_mac_mode, ret);
	else if (owns_mode)
		pr_info(SGMII_LOG_PREFIX ": reverted to port mode 0x%x / mac_mode 0x%x, loop restarted\n",
			orig_port_mode, orig_mac_mode);
	guard_remove();
}

module_init(force_sgmiiplus_init);
module_exit(force_sgmiiplus_exit);
