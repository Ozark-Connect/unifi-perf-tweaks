#!/usr/bin/env python3
"""Run the actual loader with isolated hardware stubs; no gateway access."""
import fcntl
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(os.environ.get('LOADER_UNDER_TEST', Path(__file__).resolve().parents[2] / 'scripts/20-sfp-sgmiiplus.sh'))
STUB = r'''#!PYTHON
import fcntl, json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['LOADER_TEST_ROOT'])
name = Path(sys.argv[0]).name
state_path = root / 'state.json'
s = json.loads(state_path.read_text())
def save():
    temporary = state_path.with_name('state.' + str(os.getpid()) + '.tmp')
    temporary.write_text(json.dumps(s))
    os.replace(temporary, state_path)
def event(value):
    with (root / 'events').open('a') as f: f.write(value + '\n')
if name == 'flock':
    try:
        fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
        event('locked')
    except BlockingIOError: sys.exit(1)
elif name == 'sleep':
    s['now'] += int(sys.argv[1]); s['sleeps'] += 1
    save(); (root / 'uptime').write_text(str(s['now']) + '.00 0.00\n')
    if s['scenario'] == 'clock_lost_in_hold' and s['now'] >= 120 and (root / 'clock').exists():
        (root / 'clock').unlink()
    if s['now'] >= s['end']:
        os.kill(os.getppid(), signal.SIGTERM)
    time.sleep(float(os.environ.get('LOADER_TEST_SLEEP', '0')))
elif name == 'date':
    print(s['now'] if sys.argv[1] == '+%s' else 'test-time')
elif name == 'lsmod':
    print('qca_ssdk 1 0')
    if s['loaded']: print('force_uniphy1_sgmiiplus 1 0')
elif name == 'insmod':
    s['loaded'] = True; s['loads'] += 1; s['load_at'] = s['now']; s['load_times'].append(s['now']); save(); event('insmod')
    if s['scenario'] == 'clock_disappears': (root / 'clock').unlink()
elif name == 'rmmod':
    s['loaded'] = False; s['remove_times'].append(s['now']); save(); event('rmmod')
elif name == 'ethtool':
    identity = 'aa'
    if s['scenario'] == 'swap_up': identity = 'aa' if s['now'] < 200 else 'bb'
    if s['scenario'] == 'swap_after_outage': identity = 'aa' if s['now'] < 350 else 'bb'
    if s['scenario'] == 'flapping_ids' and s['now'] >= 200:
        identity = 'bb' if (s['now'] // 60) % 2 else 'cc'
    if s['scenario'] in ('fallback_swaps', 'budget_swaps'):
        identity = format(16 + (s['now'] // 300) % 100, '02x')
    if s['scenario'] != 'empty_cage': print('0x0014: ' + ' '.join([identity] * 64))
elif name == 'cat':
    path = sys.argv[1]
    if path.endswith('/clock') and s['scenario'] == 'clock_retries' and s['loads'] < 3:
        print('125000000')
    elif path.endswith('/pcs_link'):
        up = s['scenario'] != 'fallback_swaps'
        if s['scenario'] == 'budget_swaps': up = s['now'] - s['load_at'] < 60
        if s['scenario'] in ('swap_after_outage', 'flapping_ids'): up = s['now'] < 200
        print('1' if up else '0')
    else:
        try: sys.stdout.write(Path(path).read_text())
        except OSError: sys.exit(1)
else: raise AssertionError(name)
'''


class World:
    def __init__(self, scenario='normal', end=600, missing_clock=False, missing_flock=False, bad_lock=False):
        self.temp = tempfile.TemporaryDirectory(prefix='sgmiiplus-loader-', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        stub = self.bin / 'stub'
        stub.write_text(STUB.replace('PYTHON', sys.executable, 1)); stub.chmod(0o755)
        for name in ('flock', 'sleep', 'date', 'lsmod', 'insmod', 'rmmod', 'ethtool', 'cat'):
            if name != 'flock' or not missing_flock: (self.bin / name).symlink_to(stub)
        for name in ('grep', 'awk'):
            (self.bin / name).symlink_to(shutil.which(name))
        self.state_path = self.root / 'state.json'
        import json
        self.state_path.write_text(json.dumps(dict(now=100, sleeps=0, end=end, loaded=False, loads=0, load_at=0, load_times=[], remove_times=[], scenario=scenario)))
        (self.root / 'uptime').write_text('100.00 0.00\n')
        (self.root / 'events').touch()
        (self.root / 'force_uniphy1_sgmiiplus.ko').write_text('config_aneg guard installed (ordered publication)\n')
        (self.root / 'pcs_link').touch()
        if not missing_clock: (self.root / 'clock').write_text('312500000\n')
        net = self.root / 'net'; (net / 'statistics').mkdir(parents=True)
        (net / 'carrier').write_text('1\n'); (net / 'statistics/rx_packets').write_text('1\n')
        script = SOURCE.read_text()
        replacements = {
            'LOG_FILE="/var/log/${SCRIPT_NAME}.log"': f'LOG_FILE="{self.root}/loader.log"',
            'MODULE_DIR="/data/sfp-sgmiiplus"': f'MODULE_DIR="{self.root}"',
            'CLOCK_PATH="/sys/kernel/debug/clk/uniphy1_gcc_tx_clk/clk_rate"': f'CLOCK_PATH="{self.root}/clock"',
            'PARAM_DIR="/sys/module/${MODULE_NAME}/parameters"': f'PARAM_DIR="{self.root}"',
            'STATE_FILE="/run/${MODULE_NAME}.1g-sfp"': f'STATE_FILE="{self.root}/1g-sfp"',
            'LOCK_FILE="/run/${MODULE_NAME}.loader.lock"': f'LOCK_FILE="{self.root if bad_lock else self.root / "lock"}"',
            '/sys/class/net/${IFACE}': str(net), '/proc/uptime': str(self.root / 'uptime'),
        }
        for old, new in replacements.items():
            if old != '/proc/uptime': assert old in script, old
            script = script.replace(old, new)
        self.script = self.root / 'loader.sh'; self.script.write_text(script); self.script.chmod(0o755)
        self.env = dict(os.environ, LOADER_TEST_ROOT=str(self.root), PATH=str(self.bin))
        self.processes = []
    def start(self, delay='0'):
        env = dict(self.env, LOADER_TEST_SLEEP=delay)
        p = subprocess.Popen(['/bin/sh', str(self.script), '--bg'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(p); return p
    def finish(self, p):
        out, err = p.communicate(timeout=90)
        assert not out and not err, (out, err)
        return p.returncode
    def state(self):
        import json
        return json.loads(self.state_path.read_text())
    def log(self): return (self.root / 'loader.log').read_text()
    def close(self):
        for p in self.processes:
            if p.poll() is None: p.terminate(); p.communicate(timeout=5)
        self.temp.cleanup()


class LoaderTests(unittest.TestCase):
    def world(self, **kw):
        w = World(**kw); self.addCleanup(w.close); return w
    def test_normal_success_and_hold(self):
        w = self.world(); w.finish(w.start())
        self.assertEqual(w.state()['loads'], 1)
        self.assertIn('held for 45s', w.log())
        self.assertIn('2.5G SerDes link up', w.log())
    def test_pcs_up_sfp_swap_does_not_reload(self):
        w = self.world(scenario='swap_up'); w.finish(w.start())
        self.assertEqual(w.state()['loads'], 1)
        self.assertIn('without reloading', w.log())
    def test_new_sfp_gets_full_link_timeout_after_previous_outage(self):
        # The old SFP has already spent 150s without PCS when the new ID appears.
        # Stop just before 180s after the first new-ID observation (t=351).
        # Even the interval preceding that observation must not count for it.
        w = self.world(scenario='swap_after_outage', end=530); w.finish(w.start())
        self.assertIn('without reloading', w.log())
        self.assertEqual(w.state()['loads'], 1)
        self.assertNotIn('no 2.5G link for 180s', w.log())
    def test_stable_new_sfp_reloads_after_its_full_timeout(self):
        w = self.world(scenario='swap_after_outage', end=590); w.finish(w.start())
        self.assertEqual(w.state()['load_times'][:2], [100, 531])
        self.assertEqual(w.state()['remove_times'][0], 531)
    def test_flapping_sfp_ids_cannot_extend_outage_beyond_360_seconds(self):
        w = self.world(scenario='flapping_ids', end=620); w.finish(w.start())
        # Last PCS1 observation was t=196, so the hard cap is t=556.
        self.assertEqual(w.state()['remove_times'][0], 556)
        self.assertEqual(w.state()['loads'], 2)
        self.assertIn('360s across SFP identities', w.log())
    def test_budget_includes_fallback_sfp_swaps(self):
        w = self.world(scenario='fallback_swaps', end=2200); w.finish(w.start())
        self.assertEqual(w.state()['loads'], 4)  # initial boot + three recovery runs
        self.assertIn('Recovery budget', w.log())
        self.assertGreaterEqual(w.log().count('links at stock 1G'), 4)
        self.assertGreaterEqual((w.root / 'events').read_text().count('locked'), 5)
    def test_budget_survives_loaded_and_stock_watchers(self):
        w = self.world(scenario='budget_swaps', end=2200); w.finish(w.start())
        self.assertEqual(w.state()['loads'], 4)
        self.assertIn('Recovery budget', w.log())
    def test_budget_expires(self):
        w = self.world(scenario='fallback_swaps', end=4300); w.finish(w.start())
        times = w.state()['load_times']
        self.assertGreater(len(times), 4)
        # The fifth load starts exactly when the oldest recovery admission expires,
        # not a fresh full hour after the budget was exhausted.
        self.assertEqual(times[4], times[1] + 3600)
        self.assertLess(times[3], times[4])
        self.assertIn('Recovery budget', w.log())
    def test_clock_retries_preserve_five_attempt_procedure(self):
        w = self.world(scenario='clock_retries'); w.finish(w.start())
        self.assertEqual(w.state()['loads'], 3)
        self.assertIn('attempt 3/5', w.log())
        self.assertIn('2.5G SerDes link up', w.log())
    def test_clock_disappearing_after_load_removes_module(self):
        w = self.world(scenario='clock_disappears'); self.assertEqual(w.finish(w.start()), 1)
        self.assertEqual(w.state()['loads'], 1)
        self.assertFalse(w.state()['loaded'])
    def test_clock_disappearing_during_hold_stops_without_retry(self):
        w = self.world(scenario='clock_lost_in_hold'); self.assertEqual(w.finish(w.start()), 1)
        self.assertEqual(w.state()['loads'], 1)
        self.assertFalse(w.state()['loaded'])
        self.assertIn('unreadable during hold', w.log())
    def test_old_module_marker_is_rejected(self):
        w = self.world()
        (w.root / 'force_uniphy1_sgmiiplus.ko').write_text('config_aneg guard installed\n')
        self.assertEqual(w.finish(w.start()), 1)
        self.assertEqual(w.state()['loads'], 0)
        self.assertIn('needs v5.1', w.log())
    def test_empty_cage_never_loads(self):
        w = self.world(scenario='empty_cage', end=300); w.finish(w.start())
        self.assertEqual(w.state()['loads'], 0)
    def test_missing_clock_does_not_load(self):
        w = self.world(missing_clock=True); self.assertEqual(w.finish(w.start()), 1)
        self.assertEqual(w.state()['loads'], 0)
    def test_missing_flock_does_not_load(self):
        w = self.world(missing_flock=True); self.assertEqual(w.finish(w.start()), 1)
        self.assertEqual(w.state()['loads'], 0)
    def test_unwritable_lock_does_not_load(self):
        w = self.world(bad_lock=True); self.assertNotEqual(w.finish(w.start()), 0)
        self.assertEqual(w.state()['loads'], 0)
    def test_real_lock_blocks_second_instance(self):
        w = self.world(end=10000)
        first = w.start(delay='0.03')
        deadline = time.monotonic() + 5
        while not (w.root / 'events').read_text() and time.monotonic() < deadline: time.sleep(0.01)
        self.assertIn('locked', (w.root / 'events').read_text())
        second = w.start()
        self.assertEqual(w.finish(second), 0)
        self.assertIn('Another run is active', w.log())
        self.assertIsNone(first.poll())


if __name__ == '__main__': unittest.main()
