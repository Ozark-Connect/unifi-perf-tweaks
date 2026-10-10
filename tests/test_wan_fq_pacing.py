"""Real-kernel lifecycle tests; run with root on Linux, never on live WAN.

Requires Python 3, ip, tc, network namespaces, /dev/net/tun, and a default
fq_codel root on a newly created TAP. No global networking policy is changed.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "wan-fq-pacing.py"
OWNED_HANDLE = 0x7F510000
COMMAND_TIMEOUT = 10
CONDITION_TIMEOUT = 10


class WanFqPacingIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not sys.platform.startswith("linux"):
            raise unittest.SkipTest("requires Linux network namespaces and TAP")
        if os.geteuid() != 0:
            raise unittest.SkipTest("requires root to create isolated network namespaces")
        missing = [name for name in ("ip", "tc") if shutil.which(name) is None]
        if missing:
            raise unittest.SkipTest("requires installed tools: " + ", ".join(missing))
        try:
            tun = os.stat("/dev/net/tun")
        except OSError as error:
            raise unittest.SkipTest("requires /dev/net/tun: " + str(error))
        if not stat.S_ISCHR(tun.st_mode):
            raise unittest.SkipTest("/dev/net/tun must be a character device")
        if not HELPER.is_file():
            raise AssertionError("missing helper: " + str(HELPER))
        cls.ip = shutil.which("ip")
        cls.tc = shutil.which("tc")

    def setUp(self):
        self.namespace = "wanfq-{}-{}".format(os.getpid(), uuid.uuid4().hex[:10])
        self.interface = "wan"
        self.watchers = []
        self.temporary = tempfile.TemporaryDirectory(prefix="wan-fq-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.state_directory = Path(self.temporary.name) / "state"
        result = subprocess.run(
            [self.ip, "netns", "add", self.namespace],
            capture_output=True, text=True, timeout=COMMAND_TIMEOUT,
        )
        if result.returncode:
            self.skipTest("cannot create isolated network namespace: " + result.stderr.strip())
        self.addCleanup(self._delete_namespace)
        # Cleanup callbacks are LIFO: reap watchers before removing their namespace.
        self.addCleanup(self._stop_watchers)
        self._create_tap(skip_unavailable=True)
        initial = self._status()
        self.assertIsNone(initial["state"])
        self.assertFalse(initial["owns_queue"])
        self._require_default_root(initial["current"])
        self.baseline = initial["current"]

    def _delete_namespace(self):
        result = subprocess.run(
            [self.ip, "netns", "delete", self.namespace],
            capture_output=True, text=True, timeout=COMMAND_TIMEOUT,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def _stop_watchers(self):
        # Even a failed assertion must not leave a namespace resident via a child.
        for process, output in self.watchers:
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=COMMAND_TIMEOUT)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=COMMAND_TIMEOUT)
                else:
                    process.wait(timeout=COMMAND_TIMEOUT)
            finally:
                output.close()

    def _run(self, arguments, check=True):
        result = subprocess.run(
            [self.ip, "netns", "exec", self.namespace] + list(arguments),
            capture_output=True, text=True, timeout=COMMAND_TIMEOUT,
        )
        if check:
            self.assertEqual(
                result.returncode, 0,
                "{} failed\nstdout: {}\nstderr: {}".format(
                    " ".join(str(argument) for argument in arguments),
                    result.stdout, result.stderr,
                ),
            )
        return result

    def _helper_arguments(self, mode):
        return [
            sys.executable, str(HELPER), mode,
            "--interface", self.interface,
            "--state-directory", str(self.state_directory),
        ]

    def _cli(self, mode, check=True):
        return self._run(self._helper_arguments(mode), check=check)

    def _status(self):
        result = self._cli("--status")
        try:
            status = json.loads(result.stdout)
        except ValueError:
            self.fail("--status did not emit JSON only: " + repr(result.stdout))
        self.assertIsInstance(status, dict)
        self.assertIsInstance(status["owns_queue"], bool)
        return status

    def _create_tap(self, skip_unavailable=False):
        result = self._run(
            [self.ip, "tuntap", "add", "dev", self.interface, "mode", "tap"],
            check=False,
        )
        if result.returncode and skip_unavailable:
            self.skipTest("cannot create isolated TAP: " + result.stderr.strip())
        self.assertEqual(result.returncode, 0, result.stderr)
        self._run([
            self.ip, "link", "set", "dev", self.interface,
            "txqueuelen", "1000", "up",
        ])

    def _delete_tap(self):
        self._run([self.ip, "link", "delete", "dev", self.interface])

    def _require_default_root(self, current):
        if current is None or current["kind"] != "fq_codel" or current["handle"] != 0:
            self.skipTest(
                "new TAP must inherit fq_codel handle 0; observed {!r}; "
                "global default_qdisc is intentionally not changed".format(current)
            )

    def _assert_owned(self, status, baseline=None):
        self.assertTrue(status["owns_queue"], status)
        current = status["current"]
        self.assertEqual(current["kind"], "fq")
        self.assertEqual(current["handle"], OWNED_HANDLE)
        self.assertEqual(current["interface"], self.interface)
        self.assertEqual(
            status["state"]["applied"],
            {key: current[key] for key in
             ("ifindex", "device_inode", "handle", "kind", "attributes")},
        )
        if baseline is not None:
            self.assertEqual(status["state"]["baseline"], baseline)

    def _wait_status(self, condition, process=None):
        deadline = time.monotonic() + CONDITION_TIMEOUT
        last = None
        while time.monotonic() < deadline:
            if process is not None and process.poll() is not None:
                self.fail("watcher exited unexpectedly: " + self._watcher_output(process))
            last = self._status()
            if condition(last):
                return last
            time.sleep(0.05)
        self.fail("timed out waiting for kernel/state transition; last status: {!r}".format(last))

    def _start_watcher(self):
        output = tempfile.TemporaryFile(mode="w+b", dir=self.temporary.name)
        try:
            process = subprocess.Popen(
                [self.ip, "netns", "exec", self.namespace] + self._helper_arguments("--watch"),
                stdout=output, stderr=subprocess.STDOUT,
            )
        except BaseException:
            output.close()
            raise
        self.watchers.append((process, output))
        return process

    def _watcher_output(self, process):
        for candidate, output in self.watchers:
            if candidate is process:
                output.seek(0)
                return output.read().decode("utf-8", errors="replace")
        return "no captured watcher output"

    def _terminate_watcher(self, process):
        process.send_signal(signal.SIGTERM)
        try:
            returncode = process.wait(timeout=COMMAND_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.fail("SIGTERM did not stop watcher: " + self._watcher_output(process))
        self.assertEqual(returncode, 0, self._watcher_output(process))

    def _link_limits(self):
        result = self._run([self.ip, "-j", "-d", "link", "show", "dev", self.interface])
        link = json.loads(result.stdout)[0]
        # ip versions expose different GSO fields; compare every available one,
        # without imposing defaults or relying on a particular kernel version.
        return {
            key: value for key, value in link.items()
            if key == "mtu" or key == "txqlen" or key.startswith("gso_")
        }

    def test_repeated_apply_preserves_queue_and_original_snapshot(self):
        link_limits = self._link_limits()
        self._cli("--apply")
        first = self._status()
        self._assert_owned(first, self.baseline)
        state_path = self.state_directory / (self.interface + ".json")
        first_state_bytes = state_path.read_bytes()
        self.assertEqual(json.loads(first_state_bytes), first["state"])
        self._cli("--apply")
        second = self._status()
        self.assertEqual(second, first)
        self.assertEqual(state_path.read_bytes(), first_state_bytes)
        self.assertEqual(self._link_limits(), link_limits)

    def test_restore_recovers_exact_original_configuration(self):
        link_limits = self._link_limits()
        self._cli("--apply")
        self._assert_owned(self._status(), self.baseline)
        self._cli("--restore")
        restored = self._status()
        self.assertEqual(restored["current"], self.baseline)
        self.assertFalse(restored["owns_queue"])
        self.assertEqual(self._link_limits(), link_limits)
        # A second restore must be harmless rather than resurrecting owned fq.
        self._cli("--restore")
        self.assertEqual(self._status()["current"], self.baseline)

    def test_watcher_waits_then_adopts_and_recreates_with_fresh_baseline(self):
        self._delete_tap()
        process = self._start_watcher()
        # Demonstrate that a missing interface is a wait condition, not an exit.
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            pass
        else:
            self.fail("watcher did not wait for interface: " + self._watcher_output(process))
        missing = self._status()
        self.assertIsNone(missing["current"])
        self.assertIsNone(missing["state"])
        self.assertFalse(missing["owns_queue"])
        self._create_tap()
        adopted = self._wait_status(lambda status: status["owns_queue"], process)
        self._assert_owned(adopted)
        first_baseline = adopted["state"]["baseline"]
        self.assertEqual(first_baseline["kind"], "fq_codel")
        self.assertEqual(first_baseline["handle"], 0)
        self.assertNotEqual(first_baseline, self.baseline)
        self.assertEqual(first_baseline["ifindex"], adopted["current"]["ifindex"])
        self._delete_tap()
        self._wait_status(lambda status: status["current"] is None, process)
        self._create_tap()
        recreated = self._wait_status(
            lambda status: status["owns_queue"]
            and status["state"]["baseline"] != first_baseline,
            process,
        )
        self._assert_owned(recreated)
        fresh_baseline = recreated["state"]["baseline"]
        self.assertEqual(fresh_baseline["kind"], "fq_codel")
        self.assertEqual(fresh_baseline["handle"], 0)
        self.assertEqual(fresh_baseline["ifindex"], recreated["current"]["ifindex"])
        self.assertNotEqual(fresh_baseline, first_baseline)
        # This independently observes the saved baseline after kernel restoration.
        self._terminate_watcher(process)
        restored = self._status()
        self.assertEqual(restored["current"], fresh_baseline)
        self.assertFalse(restored["owns_queue"])

    def test_sigterm_restores_owned_queue(self):
        process = self._start_watcher()
        owned = self._wait_status(lambda status: status["owns_queue"], process)
        self._assert_owned(owned, self.baseline)
        self._terminate_watcher(process)
        restored = self._status()
        self.assertEqual(restored["current"], self.baseline)
        self.assertFalse(restored["owns_queue"])

    def test_preexisting_custom_queue_is_untouched(self):
        self._run([
            self.tc, "qdisc", "replace", "dev", self.interface,
            "root", "handle", "10:", "pfifo", "limit", "123",
        ])
        custom = self._status()
        self.assertEqual(custom["current"]["kind"], "pfifo")
        # Refusal may be an error exit; the consumer invariant is no mutation.
        self._cli("--apply", check=False)
        self.assertEqual(self._status(), custom)
        self._cli("--restore", check=False)
        self.assertEqual(self._status(), custom)

    def test_preexisting_fq_including_reserved_handle_is_untouched(self):
        for handle in ("12:", "7f51:"):
            with self.subTest(handle=handle):
                self._run([
                    self.tc, "qdisc", "replace", "dev", self.interface,
                    "root", "handle", handle, "fq", "limit", "321",
                ])
                existing = self._status()
                self.assertEqual(existing["current"]["kind"], "fq")
                self.assertFalse(existing["owns_queue"])
                self._cli("--apply", check=False)
                self.assertEqual(self._status(), existing)
                self._cli("--restore", check=False)
                self.assertEqual(self._status(), existing)

    def test_foreign_replacement_is_not_overwritten_on_restore(self):
        self._cli("--apply")
        self._assert_owned(self._status(), self.baseline)
        self._run([
            self.tc, "qdisc", "replace", "dev", self.interface,
            "root", "handle", "10:", "pfifo", "limit", "123",
        ])
        foreign = self._status()
        self.assertFalse(foreign["owns_queue"])
        self._cli("--restore", check=False)
        restored = self._status()
        self.assertEqual(restored["current"], foreign["current"])
        self.assertFalse(restored["owns_queue"])

    def test_same_handle_with_modified_options_is_not_overwritten(self):
        self._cli("--apply")
        owned = self._status()
        self._assert_owned(owned, self.baseline)
        # Choose a genuinely changed configuration, not an incidental default.
        for limit in ("321", "322"):
            self._run([
                self.tc, "qdisc", "change", "dev", self.interface,
                "root", "handle", "7f51:", "fq", "limit", limit,
            ])
            modified = self._status()
            if modified["current"] != owned["current"]:
                break
        self.assertNotEqual(modified["current"], owned["current"])
        self.assertEqual(modified["current"]["handle"], OWNED_HANDLE)
        self.assertEqual(modified["current"]["kind"], "fq")
        self.assertFalse(modified["owns_queue"])
        self._cli("--restore", check=False)
        restored = self._status()
        self.assertEqual(restored["current"], modified["current"])
        self.assertFalse(restored["owns_queue"])

    def test_restore_does_not_apply_old_baseline_to_recreated_interface(self):
        self._cli("--apply")
        self._assert_owned(self._status(), self.baseline)
        self._delete_tap()
        self._create_tap()
        self._require_default_root(self._status()["current"])
        # A successor can reuse the old ifindex and even the reserved fq handle.
        # It must not inherit ownership from the destroyed interface's state.
        self._run([
            self.tc, "qdisc", "replace", "dev", self.interface,
            "root", "handle", "7f51:", "fq",
        ])
        recreated = self._status()
        self.assertFalse(recreated["owns_queue"])
        self._cli("--restore", check=False)
        restored = self._status()
        self.assertEqual(restored["current"], recreated["current"])
        self.assertFalse(restored["owns_queue"])

    def test_crashed_watcher_state_is_recoverable_by_restore(self):
        process = self._start_watcher()
        owned = self._wait_status(lambda status: status["owns_queue"], process)
        self._assert_owned(owned, self.baseline)
        process.kill()
        self.assertEqual(process.wait(timeout=COMMAND_TIMEOUT), -signal.SIGKILL)
        orphaned = self._status()
        self.assertEqual(orphaned, owned)
        self._cli("--restore")
        restored = self._status()
        self.assertEqual(restored["current"], self.baseline)
        self.assertFalse(restored["owns_queue"])


if __name__ == "__main__":
    unittest.main()
