"""Tests for the boot script and the daemon payload embedded in scripts/30-ipv6-prefix-deprecation.sh.

Run: python3 tests/test_ipv6_prefix_deprecation.py [path to 30-ipv6-prefix-deprecation.sh]
The payload is extracted from the boot script's PYEOF heredoc, so this tests exactly what ships.
"""
import os
import struct
import sys
import types
import unittest

SCRIPT = (sys.argv.pop(1) if len(sys.argv) > 1 else
          os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "30-ipv6-prefix-deprecation.sh"))


def load_payload(path):
    lines = open(path).read().split("\n")
    start = next(i for i, l in enumerate(lines) if l.endswith("<<'PYEOF'"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "PYEOF")
    mod = types.ModuleType("daemon")
    exec(compile("\n".join(lines[start + 1:end]), "payload", "exec"), mod.__dict__)
    return mod


d = load_payload(SCRIPT)

CONF = """
dhcp-range=set:net_Default_br0_IPV6,::,constructor:br0,ra-only,64,86400
ra-param=br0,high,600,1800
enable-ra
#dhcp-range=set:x,::,constructor:br9,ra-only,64,86400
#ra-param=br9,high,600,1800
dhcp-range=set:net_Lab_br34_IPV6,::,constructor:br34,ra-only,64,86400
ra-param=br34,mtu:1480,600,1200
dhcp-range=set:net_Stateful_br5,::1:0,::1:ffff,constructor:br5,64,86400
ra-param=br5,high,600,1800
dhcp-range=set:net_NoParam_br7,::,constructor:br7,ra-only,64,86400
dhcp-range=set:net_Zero_br8,::,constructor:br8,ra-only,64,86400
ra-param=br8,high,600,0
"""

OLD, NEW = "2001:db8:0:100::/64", "2001:db8:0:200::/64"


def links(dev, *entries):
    return [{"ifindex": 25, "ifname": dev, "addr_info": [dict(e) for e in entries] + [{}]}]


def addr(prefix_host, valid=14000, **extra):
    a = {"family": "inet6", "local": prefix_host, "prefixlen": 64, "scope": "global",
         "dynamic": True, "valid_life_time": valid, "preferred_life_time": 1700}
    a.update(extra)
    return a


BR = {"br0": {"prf": "high", "rl": 1800}}


def snap(*entries):
    return d.parse_addrs(links("br0", *entries), BR)


def present(s):
    return {p for prefixes in s.values() for p in prefixes}


class ParseDnsmasq(unittest.TestCase):
    def test_bridges_and_skips(self):
        bridges, skipped = d.parse_dnsmasq(CONF)
        self.assertEqual(bridges, {"br0": {"prf": "high", "rl": 1800},
                                   "br34": {"prf": "medium", "rl": 1200}})
        self.assertIn("br7: no ra-param with router lifetime", skipped)
        self.assertIn("br8: router lifetime 0 out of range", skipped)
        self.assertIn("br5: RA mode other than ra-only", skipped)
        self.assertFalse(any("br9" in s for s in skipped))

    def test_interval_only_param_is_skipped(self):
        bridges, skipped = d.parse_dnsmasq("dhcp-range=::,constructor:br0,ra-only\nra-param=br0,high,600\n")
        self.assertEqual(bridges, {})
        self.assertEqual(skipped, ["br0: no ra-param with router lifetime"])


class ParseAddrs(unittest.TestCase):
    def test_only_dynamic_global_64(self):
        s, pres = d.parse_addrs(links("br0",
                                addr("2001:db8:0:100::1"),
                                addr("2001:db8:0:300::1", valid=d.INFINITE),          # static
                                addr("fd00:1::1"),                                    # ULA
                                addr("2001:db8:0:400::1", tentative=True),
                                addr("2001:db8:0:500::1", deprecated=True),
                                dict(addr("2001:db8:0:600::1"), prefixlen=56)), BR)
        self.assertEqual(s, {"br0": {OLD: {"valid": 14000, "addrs": ["2001:db8:0:100::1"]}}})
        # Static, tentative and deprecated addresses still count as present; ULA is not global here.
        self.assertEqual(pres, {OLD, "2001:db8:0:300::/64", "2001:db8:0:400::/64", "2001:db8:0:500::/64",
                                "2001:db8:0:600::/64", "fd00:1::/64"})

    def test_link_local_only_bridge_is_empty(self):
        ll = {"family": "inet6", "local": "fe80::1", "prefixlen": 64, "scope": "link"}
        self.assertEqual(d.parse_addrs(links("br0", ll), BR), ({"br0": {}}, set()))

    def test_unwatched_and_missing_bridge(self):
        self.assertEqual(d.parse_addrs(links("br1", addr("2001:db8:0:100::1")), BR), ({}, {OLD}))
        self.assertEqual(d.parse_addrs(links("br0"), BR), ({"br0": {}}, set()))


class SendGates(unittest.TestCase):
    def test_default_route(self):
        self.assertTrue(d.has_default_route([{"dst": "default", "gateway": "fe80::1", "dev": "ppp0", "table": "201.ppp0"}]))
        self.assertFalse(d.has_default_route([{"type": "unreachable", "dst": "default", "table": "201.ppp0"}]))
        self.assertFalse(d.has_default_route([]))

    def test_drop_present(self):
        due = {"br0": ([OLD, "2001:db8:0:300::/64"], ["2001:db8:0:100::1", "2001:db8:0:300::1"])}
        self.assertEqual(d.drop_present(due, {OLD}), {"br0": (["2001:db8:0:300::/64"], ["2001:db8:0:300::1"])})
        self.assertEqual(d.drop_present(due, {OLD, "2001:db8:0:300::/64"}), {})


class BuildRa(unittest.TestCase):
    def test_layout(self):
        mac = bytes.fromhex("942a6ff200ad")
        pkt = d.build_ra("high", 1800, mac, [OLD], ["2001:db8:0:100::1"])
        typ, code, _, hop, flags, rl, reach, retrans = struct.unpack("!BBHBBHII", pkt[:16])
        self.assertEqual((typ, code, hop, flags, rl, reach, retrans), (134, 0, 0, 0x08, 1800, 0, 0))
        pio = pkt[16:48]
        self.assertEqual(struct.unpack("!BBBBIII", pio[:16]), (3, 4, 64, 0xC0, 0, 0, 0))
        self.assertEqual(pio[16:24], bytes.fromhex("20010db800000100"))
        rdnss = pkt[48:72]
        self.assertEqual(struct.unpack("!BBHI", rdnss[:8]), (25, 3, 0, 0))
        self.assertEqual(pkt[72:], bytes([1, 1]) + mac)

    def test_low_preference_and_no_rdnss(self):
        pkt = d.build_ra("low", 600, b"\0" * 6, [OLD], [])
        self.assertEqual(pkt[5], 0x18)
        self.assertEqual(len(pkt), 16 + 32 + 8)

    def test_refuses_bad_router_lifetime(self):
        for rl in (0, 59, 9001):
            with self.assertRaises(ValueError):
                d.build_ra("high", rl, b"\0" * 6, [OLD], [])


class TrackerFlow(unittest.TestCase):
    def setUp(self):
        d.random.seed(1)
        self.t = d.Tracker()
        self.now, self.mono = 1_000_000.0, 100.0

    def step(self, sp, dt=3, wall_dt=None):
        s, pres = sp
        self.now += dt if wall_dt is None else wall_dt
        self.mono += dt
        due = self.t.update(BR, s, pres, self.now, self.mono)
        for br in due:
            self.t.sent(br, self.mono)
        return due

    def test_reconnect_deprecates_after_confirmation_with_burst(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.assertEqual(self.step(snap()), {})                       # WAN down: no decision
        self.assertEqual(self.step(snap(addr("2001:db8:0:200::1"))), {})  # first miss: not confirmed
        due = self.step(snap(addr("2001:db8:0:200::1")))
        self.assertEqual(due, {"br0": ([OLD], ["2001:db8:0:100::1"])})
        stale = self.t.bridges["br0"]["stale"][OLD]
        self.assertGreaterEqual(stale["until"], self.now + d.MIN_DEPRECATE_S)
        self.assertEqual(list(self.t.bridges["br0"]["current"]), [NEW])
        sends = [0.0]
        start = self.mono
        for _ in range(60):
            if self.step(snap(addr("2001:db8:0:200::1")), dt=1):
                sends.append(self.mono - start)
        self.assertEqual(sends[:3], [0.0, 4.0, 16.0])
        self.assertTrue(all(b - a >= d.MIN_GAP_S for a, b in zip(sends, sends[1:])))
        self.assertEqual(len(sends), 3)
        self.assertTrue(self.t.dirty)

    def test_returning_prefix_stops(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.assertIn(OLD, self.t.bridges["br0"]["stale"])
        due = self.step(snap(addr("2001:db8:0:100::1")))
        self.assertEqual(self.t.bridges["br0"]["stale"], {})
        self.assertEqual(due, {})

    def test_transient_miss_is_not_a_loss(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:100::1"), addr("2001:db8:0:200::1")))
        self.assertEqual(self.t.bridges["br0"]["stale"], {})

    def test_never_sends_without_current_prefix(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        for s in (snap(), ({}, set())):
            for _ in range(50):
                self.assertEqual(self.step(s, dt=5), {})

    def test_expiry_and_cap(self):
        self.step(snap(addr("2001:db8:0:100::1", valid=600)))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        until = self.t.bridges["br0"]["stale"][OLD]["until"]
        self.assertAlmostEqual(until, self.now + d.MIN_DEPRECATE_S, delta=10)
        self.step(snap(addr("2001:db8:0:200::1")), dt=d.MIN_DEPRECATE_S + 10)
        self.assertEqual(self.t.bridges["br0"]["stale"], {})
        for i in range(12):
            host = f"2001:db8:1:{i:x}::1"
            self.step(snap(addr(host)))
            self.step(snap(addr(f"2001:db8:1:{i + 1:x}::1")))
            self.step(snap(addr(f"2001:db8:1:{i + 1:x}::1")))
        self.assertEqual(len(self.t.bridges["br0"]["stale"]), d.MAX_STALE_PER_BRIDGE)

    def test_prefix_returning_as_static_is_not_deprecated(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.assertIn(OLD, self.t.bridges["br0"]["stale"])
        due = self.step(snap(addr("2001:db8:0:100::1", valid=d.INFINITE), addr("2001:db8:0:200::1")), dt=20)
        self.assertEqual(self.t.bridges["br0"]["stale"], {})
        self.assertEqual(due, {})

    def test_old_prefix_lingering_deprecated_is_kept_until_gone(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        for _ in range(3):
            due = self.step(snap(addr("2001:db8:0:100::1", deprecated=True), addr("2001:db8:0:200::1")))
            self.assertEqual(due, {})
        self.assertIn(OLD, self.t.bridges["br0"]["current"])
        self.step(snap(addr("2001:db8:0:200::1")))
        due = self.step(snap(addr("2001:db8:0:200::1")))
        self.assertEqual(due, {"br0": ([OLD], ["2001:db8:0:100::1"])})

    def test_confirmation_counts_per_prefix(self):
        a, b, c = "2001:db8:0:a::1", "2001:db8:0:b::1", "2001:db8:0:c::1"
        self.step(snap(addr(a), addr(b)))
        self.step(snap(addr(b), addr(c)))   # a missing once
        self.step(snap(addr(a), addr(c)))   # b missing once: not yet confirmed
        self.assertEqual(self.t.bridges["br0"]["stale"], {})

    def test_clock_step_keeps_deprecation_running(self):
        self.step(snap(addr("2001:db8:0:100::1", valid=600)))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        remaining = self.t.bridges["br0"]["stale"][OLD]["until"] - self.now
        self.step(snap(addr("2001:db8:0:200::1")), dt=3, wall_dt=5 * 3600 + 3)  # NTP step +5 h
        self.assertIn(OLD, self.t.bridges["br0"]["stale"])
        self.assertAlmostEqual(self.t.bridges["br0"]["stale"][OLD]["until"] - self.now, remaining - 3, delta=1)

    def test_observation_gap_restarts_confirmation(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))          # old missing once
        self.step(({}, set()))                              # bridge not visible
        self.step(snap(addr("2001:db8:0:200::1")))          # missing once again
        self.assertEqual(self.t.bridges["br0"]["stale"], {})
        self.step(snap(addr("2001:db8:0:200::1")))
        self.assertIn(OLD, self.t.bridges["br0"]["stale"])

    def test_clock_step_leaves_times_loaded_from_disk(self):
        self.step(snap(addr("2001:db8:0:100::1", valid=14000)))
        loaded = self.t.to_state()
        expires = loaded["bridges"]["br0"]["current"][OLD]["expires"]
        self.t = d.Tracker(loaded)
        self.now -= 5 * 3600                                # boot with a clock 5 h behind
        self.step(snap(addr("2001:db8:0:100::1", valid=13990)))
        self.step(snap(addr("2001:db8:0:100::1", valid=13987)), wall_dt=5 * 3600 + 3)  # NTP step
        self.assertEqual(self.t.bridges["br0"]["current"][OLD]["expires"], expires)

    def test_missing_config_restarts_confirmation(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))          # old missing once
        self.now += 3
        self.mono += 3
        self.t.update({}, {}, set(), self.now, self.mono)   # dnsmasq config without br0
        self.step(snap(addr("2001:db8:0:200::1")))          # missing once again
        self.assertEqual(self.t.bridges["br0"]["stale"], {})

    def test_clock_step_leaves_loaded_expiry_of_a_deprecation(self):
        self.step(snap(addr("2001:db8:0:100::1", valid=14000)))
        loaded = self.t.to_state()
        expires = loaded["bridges"]["br0"]["current"][OLD]["expires"]
        self.t = d.Tracker(loaded)
        self.now -= 5 * 3600                                # boot with a clock 5 h behind
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))          # deprecated before NTP
        self.step(snap(addr("2001:db8:0:200::1")), wall_dt=5 * 3600 + 3)  # NTP step
        self.assertEqual(self.t.bridges["br0"]["stale"][OLD]["until"], expires)

    def test_second_clock_step_shifts_again(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        remaining = self.t.bridges["br0"]["stale"][OLD]["until"] - self.now
        self.step(snap(addr("2001:db8:0:200::1")), wall_dt=3600 + 3)
        self.step(snap(addr("2001:db8:0:200::1")), wall_dt=-7200 + 3)
        self.assertIn(OLD, self.t.bridges["br0"]["stale"])
        self.assertAlmostEqual(self.t.bridges["br0"]["stale"][OLD]["until"] - self.now, remaining - 6, delta=1)

    def test_static_prefix_change_is_ignored(self):
        self.step(snap(addr("2001:db8:0:100::1", valid=d.INFINITE)))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.step(snap(addr("2001:db8:0:200::1")))
        self.assertEqual(self.t.bridges["br0"]["stale"], {})

    def test_state_survives_restart(self):
        self.step(snap(addr("2001:db8:0:100::1")))
        t2 = d.Tracker(self.t.to_state())
        self.t = t2
        self.step(snap(addr("2001:db8:0:200::1")))
        due = self.step(snap(addr("2001:db8:0:200::1")))
        self.assertEqual(due, {"br0": ([OLD], ["2001:db8:0:100::1"])})
        self.assertEqual(d.Tracker({"version": 99, "bridges": {"br0": {}}}).bridges, {})

    def test_renewal_writes_rarely(self):
        # The bridge's remaining valid lifetime counts down and jumps up by 900 s on each
        # renewal (T1 900): the expiry grows in 900 s steps, written once it passes 3600 s.
        self.step(snap(addr("2001:db8:0:100::1", valid=14400)))
        self.t.dirty = False
        self.t.mark_saved()
        valid = 14400
        for renewal in range(1, 6):
            for _ in range(300):
                valid -= 3
                self.step(snap(addr("2001:db8:0:100::1", valid=valid)), dt=3)
            valid = 14400
            self.step(snap(addr("2001:db8:0:100::1", valid=valid)), dt=0)
            self.assertEqual(self.t.dirty, renewal * 900 > d.EXPIRY_WRITE_STEP_S, renewal)

class Installer(unittest.TestCase):
    """Runs the boot script's shell part with systemctl mocked and paths moved to a temp dir."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        for sub in ("data", "etc", "run", "bin"):
            os.mkdir(os.path.join(self.tmp, sub))
        self.log = os.path.join(self.tmp, "systemctl.log")
        mocks = {
            "systemctl": '#!/bin/sh\necho "$*" >> "%s"\n[ "$1" = "$FAIL" ] && exit 1\nexit 0\n' % self.log,
            "journalctl": "#!/bin/sh\nexit 0\n",
            "sleep": "#!/bin/sh\nexit 0\n",
        }
        for name, body in mocks.items():
            path = os.path.join(self.tmp, "bin", name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        self.base = (open(SCRIPT).read()
                     .replace("/data/", self.tmp + "/data/")
                     .replace("/etc/systemd/system/", self.tmp + "/etc/")
                     .replace("/run/", self.tmp + "/run/"))

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp)

    def run_script(self, text, fail=""):
        import subprocess
        path = os.path.join(self.tmp, "boot.sh")
        with open(path, "w") as f:
            f.write(text)
        if os.path.exists(self.log):
            os.remove(self.log)
        env = dict(os.environ, PATH=os.path.join(self.tmp, "bin") + ":" + os.environ["PATH"], FAIL=fail)
        rc = subprocess.run(["bash", path], env=env, capture_output=True).returncode
        calls = open(self.log).read().split("\n") if os.path.exists(self.log) else []
        return rc, calls

    def pending(self):
        return os.path.exists(os.path.join(self.tmp, "run", "ipv6-prefix-deprecation-install.restart-pending"))

    def test_failed_restart_is_retried_on_rerun(self):
        rc, calls = self.run_script(self.base)
        self.assertEqual(rc, 0)
        self.assertIn("restart ipv6-prefix-deprecation", calls)
        self.assertFalse(self.pending())

        updated = self.base.replace("\nPYEOF\n", "\n# changed\nPYEOF\n", 1)
        rc, calls = self.run_script(updated, fail="restart")
        self.assertEqual(rc, 1)

        rc, calls = self.run_script(updated)
        self.assertEqual(rc, 0)
        self.assertIn("daemon-reload", calls)
        self.assertIn("restart ipv6-prefix-deprecation", calls)
        self.assertFalse(self.pending())

        rc, calls = self.run_script(updated)
        self.assertEqual(rc, 0)
        self.assertIn("start ipv6-prefix-deprecation", calls)
        self.assertNotIn("daemon-reload", calls)


if __name__ == "__main__":
    unittest.main()
