#!/usr/bin/env python3
"""Run the actual module C with a fake SSDK; never touches kernel or hardware.

This checks control flow and the barrier protocol, not the target kernel ABI
or ARM memory-model outcomes. Use the pinned kernel build for those checks.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "modules/force-uniphy1-sgmiiplus/force_uniphy1_sgmiiplus.c"

PRELUDE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
typedef uint32_t u32;
struct mutex { int held; };
struct work_struct { void (*func)(struct work_struct *); };
typedef void (*work_func_t)(struct work_struct *);
struct delayed_work { struct work_struct work; };
struct phy_device;
struct phy_driver { const char *name; int (*config_aneg)(struct phy_device *); };
struct phy_device {
    struct { int addr; } mdio;
    struct phy_driver *drv;
    struct mutex lock;
    int speed, duplex;
    unsigned int autoneg;
    unsigned long advertising;
};
struct kernel_param { int unused; };
struct kernel_param_ops { int (*get)(char *, const struct kernel_param *); };
typedef struct { int value; } atomic_t;
#define ATOMIC_INIT(v) {v}
static void atomic_inc(atomic_t *v) { v->value++; }
static void atomic_dec(atomic_t *v) { v->value--; }
static int atomic_read(const atomic_t *v) { return v->value; }
static void observe_read(const char *);
static void observe_write(const char *);
static int writer_barriers, reader_barriers, callback_probe, publish_probe, abort_warnings;
static void test_warn(const char *format, ...);
#define READ_ONCE(x) ({ observe_read(#x); (x); })
#define WRITE_ONCE(x,v) ({ (x) = (v); observe_write(#x); })
#define smp_load_acquire(p) (*(p))
#define smp_store_release(p,v) (*(p) = (v))
#define smp_wmb() (++writer_barriers)
#define smp_rmb() (++reader_barriers)
#define smp_mb() ((void)0)
#define BUILD_BUG_ON(x) ((void)0) /* host layout is deliberately not the kernel ABI */
#define __init
#define __exit
#define MODULE_LICENSE(...)
#define MODULE_AUTHOR(...)
#define MODULE_DESCRIPTION(...)
#define MODULE_VERSION(...)
#define MODULE_PARM_DESC(...)
#define module_param_cb(...)
#define module_init(...)
#define module_exit(...)
#define pr_err(...) ((void)0)
#define pr_info(...) ((void)0)
#define pr_warn(...) test_warn(__VA_ARGS__)
#define pr_info_ratelimited(...) ((void)0)
#define UMH_NO_WAIT 0
static void msleep(unsigned int ms) { (void)ms; }
static void usleep_range(unsigned int a, unsigned int b) { (void)a; (void)b; }
static void mutex_lock(struct mutex *m) { assert(!m->held); m->held = 1; }
static int mutex_lock_killable(struct mutex *m) { mutex_lock(m); return 0; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held = 0; }
static void rtnl_lock(void);
static void rtnl_unlock(void) {}
static unsigned long kallsyms_lookup_name(const char *name);
static int call_usermodehelper(char *path, char **argv, char **envp, int wait)
{ (void)path; (void)argv; (void)envp; (void)wait; return 0; }
'''

SUFFIX = r'''
static unsigned char private_data[0x1600] __attribute__((aligned(16)));
static struct phy_driver driver;
static struct phy_device phys[7];
static struct {
    int mode, mac, force, bitmap, stopped, paused;
    int get_error, set_error, set_calls, touched, pending, snapshots, calls, suppress_pending;
} sim;

static void observe_read(const char *s)
{
    if (callback_probe && (!strcmp(s, "guard_phydev") || !strcmp(s, "orig_config_aneg")))
        assert(reader_barriers > 0);
}
static void observe_write(const char *s)
{
    if (!strcmp(s, "guard_phydev") || !strcmp(s, "orig_config_aneg"))
        writer_barriers = 0;
    if (publish_probe && !strcmp(s, "drv->config_aneg")) {
        assert(writer_barriers > 0);
        reader_barriers = 0;
        callback_probe = 1;
        assert(driver.config_aneg(&phys[6]) == 37);
        callback_probe = 0;
        publish_probe = 0;
    }
}
static void test_warn(const char *format, ...)
{
    if (strstr(format, "takeover aborted after ignoring")) abort_warnings++;
}
static void rtnl_lock(void)
{
    assert(!cfg_mutex || !cfg_mutex->held);
    if (sim.suppress_pending) {
        assert(driver.config_aneg(&phys[5]) == 0);
        sim.suppress_pending = 0;
    }
    /* A stock callback which was already running completes while the guard
     * drains old callers. The snapshot must see this complete new state. */
    if (sim.pending) { sim.mode = 4; sim.mac = 0xf; sim.force = 1; sim.pending = 0; }
}
int ssdk_mac_sw_sync_work_stop(unsigned int dev) { sim.stopped = 1; return 0; }
int ssdk_mac_sw_sync_work_start(unsigned int dev) { assert(!cfg_mutex->held); sim.stopped = 0; return 0; }
static void sync_task(struct work_struct *w) {}
static void mib_task(struct work_struct *w) {}
static void pause_mib(unsigned long p) { assert(sim.stopped); sim.paused = 1; }
static int resume_mib(unsigned long p) { assert(!cfg_mutex->held); sim.paused = 0; return 0; }
static unsigned long get_priv(unsigned int dev) { return (unsigned long)private_data; }
static int get_mode(unsigned int dev, unsigned int port, int *out)
{
    assert(cfg_mutex->held && sim.stopped && sim.paused);
    assert(guard_active && driver.config_aneg == guarded_config_aneg);
    sim.snapshots++;
    *out = sim.mode;
    return sim.get_error;
}
static unsigned int get_mac(unsigned int dev, unsigned int idx)
{ assert(cfg_mutex->held); return sim.mac; }
static int get_force(unsigned int dev, unsigned int port, unsigned int f)
{ assert(cfg_mutex->held); return sim.force; }
static int phy_get(unsigned int dev, unsigned int port, struct phy_device **pd)
{ *pd = &phys[port]; return 0; }
static unsigned int phy_port(unsigned int dev, struct phy_device *pd)
{ return (unsigned int)(pd - phys); }
static int stock_aneg(struct phy_device *pd) { sim.calls++; return 37; }
static unsigned int bitmap_get(unsigned int dev) { return sim.bitmap; }
static void bitmap_set(unsigned int dev, unsigned int bmp)
{ assert(cfg_mutex->held); sim.bitmap = bmp; }
static int mode_set(unsigned int dev, unsigned int idx, int mode)
{
    assert(cfg_mutex->held && sim.stopped && sim.paused);
    sim.set_calls++; sim.touched++;
    if (sim.set_error && sim.set_calls == 1) return sim.set_error;
    sim.mac = mode;
    return 0;
}
static int iface_set(unsigned int dev, unsigned long port, int mode)
{ assert(cfg_mutex->held); sim.mode = mode; return 0; }
static int mac_set(unsigned long dev, int idx, unsigned int mode)
{ assert(cfg_mutex->held); sim.mac = mode; return 0; }
static int feature_set(unsigned int dev, unsigned int port, unsigned int f)
{ assert(cfg_mutex->held); sim.force = 1; return 0; }
static int feature_clear(unsigned int dev, unsigned int port, unsigned int f)
{ assert(cfg_mutex->held); sim.force = 0; return 0; }
static int hw3(unsigned int a, unsigned int b, unsigned int c)
{ assert(cfg_mutex->held); sim.touched++; return 0; }
static int mac_enable(unsigned int a, unsigned int b, int c)
{ assert(cfg_mutex->held); sim.touched++; return 0; }
static int hw2(unsigned int a, unsigned int b)
{ assert(cfg_mutex->held); sim.touched++; return 0; }
static void status_init(unsigned int a, unsigned int b)
{ assert(cfg_mutex->held); }
static int io6(unsigned int a, unsigned int b, u32 *v)
{ assert(cfg_mutex->held); *v = 1u << 7; return 0; }
static unsigned long kallsyms_lookup_name(const char *s)
{
#define MAP(n,f) if (!strcmp(s,n)) return (unsigned long)(f)
    MAP("adpt_hppe_uniphy_mode_set", mode_set);
    MAP("_adpt_hppe_port_interface_mode_set", iface_set);
    MAP("adpt_hppe_port_interface_mode_get", get_mode);
    MAP("ssdk_dt_global_set_mac_mode", mac_set);
    MAP("ssdk_dt_global_get_mac_mode", get_mac);
    MAP("qca_ssdk_port_bmp_get", bitmap_get);
    MAP("qca_ssdk_port_bmp_set", bitmap_set);
    MAP("hsl_port_phydev_get", phy_get);
    MAP("qca_ssdk_phydev_to_port", phy_port);
    MAP("hppe_uniphy_channel0_input_output_6_get", io6);
    MAP("qca_mac_port_status_init", status_init);
    MAP("sfp_phy_config_aneg", stock_aneg);
    MAP("hsl_port_feature_get", get_force);
    MAP("hsl_port_feature_set", feature_set);
    MAP("hsl_port_feature_clear", feature_clear);
    MAP("hppe_uniphy_channel0_force_speed_mode_set", hw3);
    MAP("adpt_hppe_port_txmac_status_set", mac_enable);
    MAP("adpt_hppe_port_rxmac_status_set", mac_enable);
    MAP("adpt_hppe_port_bridge_txmac_set", mac_enable);
    MAP("adpt_hppe_gcc_uniphy_clock_status_set", mac_enable);
    MAP("adpt_hppe_gcc_port_speed_clock_set", hw3);
    MAP("adpt_hppe_port_mac_speed_set", hw3);
    MAP("adpt_hppe_port_mac_duplex_set", hw3);
    MAP("adpt_hppe_uniphy_port_adapter_reset", hw2);
    MAP("qca_phy_mib_work_pause", pause_mib);
    MAP("qca_phy_mib_work_resume", resume_mib);
    MAP("qca_phy_mib_work_task", mib_task);
    MAP("qca_mac_sw_sync_work_task", sync_task);
    MAP("ssdk_phy_priv_data_get", get_priv);
    return 0;
#undef MAP
}
static void setup(void)
{
    memset(&sim, 0, sizeof(sim));
    memset(private_data, 0, sizeof(private_data));
    driver.name = "QCA SFP"; driver.config_aneg = stock_aneg;
    for (int i = 0; i < 7; i++) { phys[i].drv = &driver; phys[i].lock.held = 0; }
    ((struct delayed_work *)(private_data + PRIV_SYNC_WORK))->work.func = sync_task;
    ((struct delayed_work *)(private_data + PRIV_MIB_WORK))->work.func = mib_task;
    sim.mode = 0xe; sim.mac = 0x14; sim.bitmap = 0x7f;
    *(unsigned int *)(private_data + SPEED_CACHE_BASE + 4 * PORT_STRIDE) = 1000;
    *(unsigned int *)(private_data + DUPLEX_CACHE_BASE + 4 * PORT_STRIDE) = 1;
}
static void cleaned_up(void)
{
    assert(!cfg_mutex->held && !sim.stopped && !sim.paused);
    assert(driver.config_aneg == stock_aneg && !guard_active && !guard_drv);
    assert(sim.bitmap == 0x7f);
}
int main(int argc, char **argv)
{
    assert(argc == 2); setup();
    const char *name = argv[1];
    if (!strcmp(name, "snapshot_after_drain")) sim.pending = 1;
    if (!strcmp(name, "get_failure")) sim.get_error = -5;
    if (!strcmp(name, "bad_pair")) sim.mac = 0x77;
    if (!strcmp(name, "abort_suppressed")) { sim.mac = 0x77; sim.suppress_pending = 1; }
    if (!strcmp(name, "mode_failure")) { sim.mode = 4; sim.mac = 0xf; sim.force = 1; sim.set_error = -7; }
    if (!strcmp(name, "publication")) publish_probe = 1;
    int ret = force_sgmiiplus_init();
    if (!strcmp(name, "get_failure") || !strcmp(name, "bad_pair") || !strcmp(name, "abort_suppressed")) {
        assert(ret == (!strcmp(name, "get_failure") ? -EIO : -EBUSY));
        assert(!sim.touched && !sim.set_calls); cleaned_up();
        if (!strcmp(name, "abort_suppressed")) assert(abort_warnings == 1);
    } else if (!strcmp(name, "mode_failure")) {
        assert(ret == -7 && sim.mac == 0xf && sim.force == 1);
        assert(sim.set_calls == 2); cleaned_up();
    } else {
        assert(ret == 0 && sim.snapshots == 1);
        if (!strcmp(name, "snapshot_after_drain"))
            assert(orig_port_mode == 4 && orig_mac_mode == 0xf && orig_force == 1);
        assert(driver.config_aneg(&phys[5]) == 0);
        assert(driver.config_aneg(&phys[6]) == 37);
        assert(sim.bitmap == (0x7f & ~(1 << 5)));
        force_sgmiiplus_exit(); cleaned_up();
        assert(sim.mode == orig_port_mode && sim.mac == (int)orig_mac_mode && sim.force == orig_force);
    }
    puts(name); return 0;
}
'''


class ModuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ.get("MODULE_SOURCE", SOURCE)).read_text()
        source = re.sub(r"^#include[^\n]*", "", source, flags=re.M)
        cls.temp = tempfile.TemporaryDirectory(prefix="pr14-module-", dir="/private/tmp")
        cls.addClassCleanup(cls.temp.cleanup)
        cfile = Path(cls.temp.name) / "module-test.c"
        cls.binary = Path(cls.temp.name) / "module-test"
        cfile.write_text(PRELUDE + source + SUFFIX)
        flags = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if os.environ.get("MODULE_TEST_SANITIZERS") == "1" else []
        result = subprocess.run([os.environ.get("CC", "cc"), "-std=gnu11", "-O2", *flags, "-Wall", "-Wextra", "-Werror",
                                 "-Wno-unused-function", "-Wno-unused-variable", "-Wno-unused-parameter",
                                 "-Wno-deprecated-declarations",  # host libc marks kernel sprintf deprecated
                                 str(cfile), "-o", str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.binary), name], text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_snapshot_waits_for_old_callback_and_config_mutex(self):
        self.scenario("snapshot_after_drain")

    def test_snapshot_read_failure_releases_guard_and_workers(self):
        self.scenario("get_failure")

    def test_unsupported_pair_does_not_touch_hardware(self):
        self.scenario("bad_pair")

    def test_failed_mode_set_restores_original_force_and_mode(self):
        self.scenario("mode_failure")

    def test_aborted_takeover_reports_suppressed_requests(self):
        self.scenario("abort_suppressed")

    def test_callback_publication_orders_other_port_dependencies(self):
        self.scenario("publication")

    def test_takeover_and_unload_restore_original_state(self):
        self.scenario("normal")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=SOURCE)
    args, remaining = parser.parse_known_args()
    os.environ["MODULE_SOURCE"] = str(args.source)
    unittest.main(argv=[__file__] + remaining)
