#!/usr/bin/env python3
"""Opt-in fq socket pacing; preserve packetization and restore only owned queues."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys

ROOT = 0xFFFFFFFF
OWN_HANDLE = 0x7F510000
NEW, DELETE, GET = 36, 37, 38
REQUEST, ACK, DUMP, CREATE, REPLACE = 1, 4, 0x300, 0x400, 0x100
MISSING_DEVICE = (6, 19)


def align(n):
    return (n + 3) & ~3

def attributes(data):
    result = []
    offset = 0
    while offset + 4 <= len(data):
        length, kind = struct.unpack_from("=HH", data, offset)
        if length < 4 or offset + length > len(data):
            raise RuntimeError("Invalid netlink attribute")
        result.append((kind, data[offset + 4:offset + length]))
        offset += align(length)
    return result

def encode_attributes(items):
    output = bytearray()
    for kind, value in items:
        length = 4 + len(value)
        output.extend(struct.pack("=HH", length, kind))
        output.extend(value)
        output.extend(b"\0" * (align(length) - length))
    return bytes(output)

def netlink(message_type, flags, payload):
    with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE) as sock:
        sock.bind((0, 0))
        sock.settimeout(5)
        sequence = 1
        header = struct.pack("=IHHII", 16 + len(payload), message_type, flags, sequence, 0)
        sock.send(header + payload)
        records = []
        while True:
            packet = sock.recv(1024 * 1024)
            offset = 0
            while offset + 16 <= len(packet):
                length, kind, reply_flags, seq, pid = struct.unpack_from("=IHHII", packet, offset)
                if length < 16 or offset + length > len(packet):
                    raise RuntimeError("Invalid netlink message")
                body = packet[offset + 16:offset + length]
                offset += align(length)
                if seq != sequence:
                    continue
                if kind == 2:
                    error = struct.unpack_from("=i", body)[0]
                    if error:
                        raise OSError(-error, os.strerror(-error))
                    return records
                if kind == 3:
                    if len(body) >= 4:
                        error = struct.unpack_from("=i", body)[0]
                        if error:
                            raise OSError(-error, os.strerror(-error))
                    if reply_flags & 0x10:
                        raise RuntimeError("Interrupted netlink dump; refusing incomplete snapshot")
                    return records
                records.append((kind, body))

def tc_message(index, handle=0, parent=ROOT):
    return struct.pack("=BxxxiIII", socket.AF_UNSPEC, index, handle, parent, 0)

def root_snapshot(interface):
    index = socket.if_nametoindex(interface)
    device_path = Path("/sys/class/net") / interface
    device_inode = device_path.stat().st_ino
    roots = []
    for kind, body in netlink(GET, REQUEST | DUMP, tc_message(index)):
        if kind != NEW or len(body) < 20:
            continue
        family, device, handle, parent, info = struct.unpack_from("=BxxxiIII", body)
        if device != index or parent != ROOT:
            continue
        attrs = attributes(body[20:])
        values = {typ & 0x3FFF: value for typ, value in attrs}
        functional = [(typ, value) for typ, value in attrs if (typ & 0x3FFF) in (1, 2, 8)]
        if 1 not in values:
            raise RuntimeError("Root queue kind missing")
        # Filter/block/estimator state is not represented by these three attributes.
        if any((typ & 0x3FFF) in (5, 11, 13, 14) for typ, value in attrs):
            raise RuntimeError("Unsupported root queue attachment; refusing to change it")
        roots.append({"interface": interface, "ifindex": index, "device_inode": device_inode,
                      "handle": handle, "kind": values[1].rstrip(b"\0").decode(),
                      "attributes": [[typ, value.hex()] for typ, value in functional]})
    if device_path.stat().st_ino != device_inode:
        raise OSError(19, "Interface was recreated during queue lookup")
    if not roots:
        raise OSError(19, "Interface queue is not ready")
    if len(roots) != 1:
        raise RuntimeError("Expected exactly one root queue")
    return roots[0]

def same_device(left, right):
    return all(left[key] == right[key] for key in ("ifindex", "device_inode"))


def configuration(snapshot):
    return {key: snapshot[key] for key in
            ("ifindex", "device_inode", "handle", "kind", "attributes")}

def preflight(interface):
    baseline = root_snapshot(interface)
    if baseline["kind"] != "fq_codel":
        raise RuntimeError("Expected fq_codel; refusing to replace a different queue")
    for argv in (["tc", "-j", "class", "show", "dev", interface],
                 ["tc", "-j", "filter", "show", "dev", interface],
                 ["tc", "-j", "filter", "show", "dev", interface, "ingress"],
                 ["tc", "-j", "filter", "show", "dev", interface, "egress"]):
        text = subprocess.check_output(argv, text=True).strip()
        if text and json.loads(text):
            raise RuntimeError("Existing classes/filters; refusing to change the queue")
    return baseline

def save_state(path, state):
    temporary = path.with_suffix(".new")
    with temporary.open("w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(state, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)

def restore_attributes(baseline):
    result = []
    for kind, value in baseline["attributes"]:
        payload = bytes.fromhex(value)
        if (kind & 0x3FFF) == 2:
            options = []
            for option, data in attributes(payload):
                if (option & 0x3FFF) in (1, 3):
                    # CoDel stores time in 1024 ns ticks, but dumps truncated us.
                    # Sending dumped_us + 1 recovers the same internal tick.
                    microseconds = struct.unpack("=I", data)[0]
                    data = struct.pack("=I", microseconds + 1)
                options.append((option, data))
            payload = encode_attributes(options)
        result.append((kind, payload))
    return encode_attributes(result)


class Controller:
    def __init__(self, interface, directory):
        self.interface = interface
        self.directory = Path(directory)
        self.path = self.directory / (interface + ".json")

    def state(self):
        try:
            return json.loads(self.path.read_text())
        except FileNotFoundError:
            return None

    def current(self):
        try:
            return root_snapshot(self.interface)
        except OSError as error:
            if error.errno in MISSING_DEVICE:
                return None
            # if_nametoindex() is documented to raise OSError, but Python may
            # omit errno. Verify absence rather than matching its error text.
            if self.interface not in {name for index, name in socket.if_nameindex()}:
                return None
            raise

    def owns(self, current, state):
        if current is None or state is None:
            return False
        if not same_device(current, state["baseline"]):
            return False
        if state["applied"] is not None:
            return configuration(current) == state["applied"]
        # The durable intent precedes the kernel mutation. This reserved handle
        # also permits rollback if killed before the first applied readback.
        return current["kind"] == "fq" and current["handle"] == OWN_HANDLE

    def status(self):
        current, state = self.current(), self.state()
        return {"current": current, "state": state,
                "owns_queue": self.owns(current, state)}

    def apply(self):
        current = self.current()
        if current is None:
            return False
        state = self.state()
        if state is not None and not same_device(current, state["baseline"]):
            self.path.unlink()
            state = None  # The old interface and its queue no longer exist.
        if state is not None:
            if state["applied"] is not None:
                return False  # Already applied, or another actor changed it.
            if self.owns(current, state):
                state["applied"] = configuration(current)
                save_state(self.path, state)
                return False
            if configuration(current) != configuration(state["baseline"]):
                return False
        elif current["kind"] != "fq_codel" or current["handle"] != 0:
            return False  # Do not adopt pre-existing fq or custom root queues.
        try:
            if state is None:
                baseline = preflight(self.interface)
                if configuration(baseline) != configuration(current):
                    return False
                state = {"baseline": baseline, "applied": None}
                save_state(self.path, state)
            if configuration(root_snapshot(self.interface)) != configuration(state["baseline"]):
                return False
            netlink(NEW, REQUEST | ACK | CREATE | REPLACE,
                    tc_message(current["ifindex"], OWN_HANDLE)
                    + encode_attributes([(1, b"fq\0")]))
            applied = root_snapshot(self.interface)
            if not self.owns(applied, state):
                raise RuntimeError("fq ownership readback did not match")
            state["applied"] = configuration(applied)
            save_state(self.path, state)
            print("Applied automatic fq pacing to " + self.interface, flush=True)
            return True
        except (OSError, subprocess.CalledProcessError):
            actual = self.current()
            if actual is None or not same_device(actual, current):
                return False  # A queued link event will reconcile its successor.
            self.restore()
            raise
        except BaseException:
            self.restore()
            raise

    def restore(self):
        state = self.state()
        if state is None:
            return
        current = self.current()
        baseline = state["baseline"]
        if current is None or not same_device(current, baseline):
            self.path.unlink()
            return
        if configuration(current) == configuration(baseline):
            self.path.unlink()
            return
        if not self.owns(current, state):
            self.path.unlink()
            print("Leaving externally changed queue untouched on " + self.interface,
                  flush=True)
            return
        netlink(DELETE, REQUEST | ACK, tc_message(current["ifindex"], OWN_HANDLE))
        reset = root_snapshot(self.interface)
        if configuration(reset) != configuration(baseline):
            if reset["kind"] != baseline["kind"] or reset["handle"] != 0:
                raise RuntimeError("Kernel default queue changed; exact restoration refused")
            netlink(NEW, REQUEST | ACK,
                    tc_message(baseline["ifindex"]) + restore_attributes(baseline))
        if configuration(root_snapshot(self.interface)) != configuration(baseline):
            raise RuntimeError("Original queue configuration did not restore exactly")
        self.path.unlink()
        print("Restored original queue configuration on " + self.interface, flush=True)

    def watch(self):
        def stop(signum, frame):
            for item in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(item, signal.SIG_IGN)
            raise SystemExit(0)

        for item in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(item, stop)
        with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW,
                           socket.NETLINK_ROUTE) as events:
            events.bind((0, 1))  # RTMGRP_LINK; bind before the initial snapshot.
            try:
                self.apply()
                print("Watching interface lifecycle for " + self.interface, flush=True)
                while True:
                    packet = events.recv(1024 * 1024)
                    offset, relevant = 0, False
                    while offset + 16 <= len(packet):
                        length, kind, flags, sequence, pid = struct.unpack_from(
                            "=IHHII", packet, offset)
                        if length < 16 or offset + length > len(packet):
                            raise RuntimeError("Invalid link event")
                        body = packet[offset + 16:offset + length]
                        offset += align(length)
                        if kind == 4:  # NLMSG_OVERRUN
                            raise RuntimeError("Lost link events; stopping pacing safely")
                        if kind not in (16, 17) or len(body) < 16:
                            continue
                        names = [value.rstrip(b"\0").decode() for typ, value
                                 in attributes(body[16:]) if (typ & 0x3FFF) == 3]
                        relevant = relevant or self.interface in names
                    if relevant:
                        self.apply()
            finally:
                self.restore()


def interface_name(value):
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.:-]{0,14}", value):
        raise argparse.ArgumentTypeError("Expected a Linux interface name")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    for mode in ("apply", "watch", "restore", "status"):
        modes.add_argument("--" + mode, action="store_true")
    parser.add_argument("--interface", type=interface_name, default="ppp0")
    parser.add_argument("--state-directory", type=Path, default=Path("/run/wan-fq-pacing"))
    args = parser.parse_args()
    controller = Controller(args.interface, args.state_directory)
    if args.status:
        print(json.dumps(controller.status(), indent=2))
        return
    if os.geteuid() != 0:
        raise RuntimeError("Changing WAN queues requires root")
    controller.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (controller.directory / (args.interface + ".lock")).open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if args.apply or args.watch:
                print("A watcher already manages " + args.interface, flush=True)
                return
            raise RuntimeError("Stop the watcher before restoring its queue")
        if args.watch:
            controller.watch()
        elif args.apply:
            controller.apply()
        else:
            controller.restore()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("ERROR: " + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
