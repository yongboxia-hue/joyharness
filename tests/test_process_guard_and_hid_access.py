"""Tests for the three defects behind the 2026-09-14 unexpected exits.

Each test reproduces the shape of the original failure rather than asserting
that some line of code is still present: hidapi entered by two threads at
once, a second runtime starting beside a live one, and a runtime outliving the
app that owns it.
"""

from __future__ import annotations

import multiprocessing
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import hid_access  # noqa: E402
from src.process_guard import SingleInstanceLock, watch_parent  # noqa: E402


class HidAccessSerialisationTests(unittest.TestCase):
    """hidapi must never be entered by two threads at once."""

    def setUp(self) -> None:
        self._real_hid = hid_access.hid

    def tearDown(self) -> None:
        hid_access.hid = self._real_hid

    def test_concurrent_enumerate_never_overlaps(self) -> None:
        inside = 0
        overlaps = 0
        bookkeeping = threading.Lock()

        class FakeHid:
            @staticmethod
            def enumerate(vendor_id, product_id):
                nonlocal inside, overlaps
                with bookkeeping:
                    inside += 1
                    if inside > 1:
                        overlaps += 1
                # Stand in for the real call's window with the GIL released.
                time.sleep(0.002)
                with bookkeeping:
                    inside -= 1
                return []

        hid_access.hid = FakeHid

        threads = [
            threading.Thread(target=lambda: [hid_access.enumerate_devices(1, 2)
                                             for _ in range(40)])
            for _ in range(4)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(overlaps, 0,
                         "two threads were inside hidapi at once; that is the "
                         "condition that aborted the runtime out of malloc")

    def test_open_and_enumerate_are_mutually_exclusive(self) -> None:
        """Opening is global-state work too, so it must exclude enumerate."""
        inside = 0
        overlaps = 0
        bookkeeping = threading.Lock()

        def busy():
            nonlocal inside, overlaps
            with bookkeeping:
                inside += 1
                if inside > 1:
                    overlaps += 1
            time.sleep(0.002)
            with bookkeeping:
                inside -= 1

        class FakeDevice:
            def open_path(self, path):
                busy()

            def close(self):
                busy()

        class FakeHid:
            @staticmethod
            def enumerate(vendor_id, product_id):
                busy()
                return []

            @staticmethod
            def device():
                return FakeDevice()

        hid_access.hid = FakeHid

        def opener():
            for _ in range(30):
                device = hid_access.open_path(b"/dev/fake")
                hid_access.close(device)

        def enumerator():
            for _ in range(30):
                hid_access.enumerate_devices(1, 2)

        threads = [threading.Thread(target=opener), threading.Thread(target=enumerator),
                   threading.Thread(target=opener)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(overlaps, 0, "open and enumerate ran concurrently")

    def test_failed_open_closes_the_handle(self) -> None:
        """A handle abandoned half-open is what corrupts the device list."""
        closed = []

        class FakeDevice:
            def open_path(self, path):
                raise OSError("open failed")

            def close(self):
                closed.append(True)

        class FakeHid:
            @staticmethod
            def device():
                return FakeDevice()

        hid_access.hid = FakeHid

        with self.assertRaises(OSError):
            hid_access.open_path(b"/dev/fake")
        self.assertEqual(closed, [True], "the handle was left open after a failed open")


def _try_to_acquire(path_str, result):
    """Acquire the lock in a separate process; report whether it succeeded."""
    from src.process_guard import SingleInstanceLock as Lock
    result.value = 1 if Lock(Path(path_str)).acquire() else 0


class SingleInstanceLockTests(unittest.TestCase):
    """A second runtime must not start beside a live one."""

    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.lock_path = Path(self._dir.name) / "runtime.lock"

    def tearDown(self) -> None:
        self._dir.cleanup()

    def _acquire_in_child(self) -> bool:
        # flock is per open file description, so a second attempt has to come
        # from another process to mean anything.
        ctx = multiprocessing.get_context("spawn")
        result = ctx.Value("i", -1)
        child = ctx.Process(target=_try_to_acquire, args=(str(self.lock_path), result))
        child.start()
        child.join(30)
        self.assertEqual(child.exitcode, 0, "lock probe process failed")
        return bool(result.value)

    def test_second_process_is_refused_while_the_first_holds_it(self) -> None:
        first = SingleInstanceLock(self.lock_path)
        self.assertTrue(first.acquire())
        try:
            self.assertFalse(self._acquire_in_child(),
                             "a second runtime started beside a live one")
        finally:
            first.release()

    def test_lock_is_available_again_after_release(self) -> None:
        first = SingleInstanceLock(self.lock_path)
        self.assertTrue(first.acquire())
        first.release()
        self.assertTrue(self._acquire_in_child(),
                        "the lock stayed held after release, locking out every later launch")

    def test_lock_is_released_when_the_holder_dies_uncleanly(self) -> None:
        """The reason this is flock and not a PID file.

        A process killed with SIGKILL cannot clean up after itself. The kernel
        drops its flock anyway; a stale PID file would have locked out every
        later launch.
        """
        ctx = multiprocessing.get_context("spawn")
        holder = ctx.Process(target=_hold_lock_forever, args=(str(self.lock_path),))
        holder.start()
        deadline = time.time() + 30
        while time.time() < deadline and not self.lock_path.exists():
            time.sleep(0.05)
        time.sleep(0.5)
        self.assertFalse(self._acquire_in_child(), "the holder never took the lock")
        holder.kill()
        holder.join(30)
        self.assertTrue(self._acquire_in_child(),
                        "the lock survived its holder being killed")


def _hold_lock_forever(path_str):
    from src.process_guard import SingleInstanceLock as Lock
    lock = Lock(Path(path_str))
    if lock.acquire():
        time.sleep(300)


class ParentWatchTests(unittest.TestCase):
    """A runtime must not outlive the app that owns it."""

    def test_stops_when_the_parent_changes(self) -> None:
        stop_event = threading.Event()
        real_getppid = os.getppid
        # The watcher must start while a real parent is reported, then see it
        # change -- patching before the call would just look like "no parent".
        reported_parent = [4242]
        os.getppid = lambda: reported_parent[0]
        try:
            thread = watch_parent(stop_event)
            self.assertIsNotNone(thread, "no watcher started despite a real parent")
            self.assertFalse(stop_event.wait(0.5),
                             "stopped while the parent was still alive")
            # Stand in for the app dying: the child is reparented to launchd.
            reported_parent[0] = 1
            self.assertTrue(stop_event.wait(30),
                            "the runtime kept going after its parent went away")
        finally:
            os.getppid = real_getppid
            stop_event.set()

    def test_no_watcher_when_already_parented_to_launchd(self) -> None:
        """Otherwise a runtime started from a closed terminal quits at once."""
        stop_event = threading.Event()
        real_getppid = os.getppid
        os.getppid = lambda: 1
        try:
            self.assertIsNone(watch_parent(stop_event))
            self.assertFalse(stop_event.is_set())
        finally:
            os.getppid = real_getppid


class StatusScratchFileTests(unittest.TestCase):
    """Two runtimes must not share one scratch file name."""

    def test_scratch_file_is_named_for_this_process(self) -> None:
        # Reimporting with the IPC directory redirected keeps the test off the
        # real one, which the installed app is using.
        import importlib

        with tempfile.TemporaryDirectory() as directory:
            os.environ["JOYHARNESS_IPC_DIR"] = directory
            try:
                import src.runtime_ipc as runtime_ipc
                runtime_ipc = importlib.reload(runtime_ipc)
                runtime_ipc.ensure_ipc_dir()

                observed = []
                original_replace = Path.replace

                def spy(self, target):
                    observed.append(self.name)
                    return original_replace(self, target)

                Path.replace = spy
                try:
                    bridge = runtime_ipc.RuntimeIpcBridge(_StubRuntime())
                    bridge._publish_status()
                finally:
                    Path.replace = original_replace

                self.assertEqual(observed, [f"status.{os.getpid()}.tmp"],
                                 "the scratch file is shared between processes again")
                self.assertTrue((Path(directory) / "status.json").exists())
                # Nothing left behind for the next process to trip over.
                leftovers = [p.name for p in Path(directory).glob("*.tmp")]
                self.assertEqual(leftovers, [], f"scratch files left behind: {leftovers}")
            finally:
                os.environ.pop("JOYHARNESS_IPC_DIR", None)
                importlib.reload(runtime_ipc)


class SignalHandlerSafetyTests(unittest.TestCase):
    """A signal must never be handled by something that takes a lock.

    0.1.8 logged from its SIGTERM handler. logging takes a lock, the readers
    log every two seconds, and a signal arriving while that lock was held left
    the handler waiting on a lock only the interrupted frame could release.
    The runtime never exited and the app, which waited on it without a
    timeout, hung on quit -- reported as "退出就会卡死" with a macOS hang
    report showing the main thread parked in waitUntilExit.
    """

    def test_handler_exits_even_while_the_logging_lock_is_held(self) -> None:
        import logging as logging_module
        import subprocess

        program = """
import logging, os, signal, sys, threading, time
sys.path.insert(0, %r)
logging.basicConfig(level=logging.INFO, stream=sys.stderr)
from src.process_guard import record_lifecycle
record_lifecycle()

def hog():
    logging._lock.acquire()
    for handler in logging.getLogger().handlers:
        handler.lock.acquire()
    time.sleep(120)

threading.Thread(target=hog, daemon=True).start()
time.sleep(0.4)
os.kill(os.getpid(), signal.SIGTERM)
time.sleep(10)
os._exit(99)   # reached only if the handler deadlocked
""" % str(Path(__file__).resolve().parent.parent)

        result = subprocess.run([sys.executable, "-c", program],
                                capture_output=True, text=True, timeout=120)
        self.assertNotEqual(
            result.returncode, 99,
            "the signal handler blocked while the logging lock was held; "
            "it must not take locks",
        )
        self.assertEqual(result.returncode, 128 + 15,
                         f"expected exit on SIGTERM, got {result.returncode}")


class _StubRuntime:
    """Just enough runtime for one status publish."""

    stop_event = threading.Event()
    started = True
    connection_mode = "none"
    config_path = None

    def input_events_snapshot(self):
        return []

    def __getattr__(self, name):
        return None


class LifecycleLoggingTests(unittest.TestCase):
    """A runtime that is killed must say so before it goes.

    Three runtimes in the 2026-09-15 diagnostic package each left exactly one
    line -- the config path -- and nothing about why they stopped. That is
    indistinguishable from a crash, a hang, or a runtime that never started,
    and it cost a whole round of diagnosis.
    """

    def _run_until(self, marker: str, then_signal=None):
        """Start the runtime, wait for a marker, optionally signal it."""
        import subprocess, signal as sig
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "user.json"
            config.write_text((Path(__file__).resolve().parent.parent
                               / "config" / "user.json").read_text(), encoding="utf-8")
            log = Path(directory) / "out.log"
            env = dict(os.environ, JOYHARNESS_IPC_DIR=str(Path(directory) / "ipc"))
            with log.open("w") as sink:
                child = subprocess.Popen(
                    [sys.executable, "-m", "src", "--native-client",
                     "--no-admin-warn", "--config", str(config)],
                    stdout=sink, stderr=sink, env=env,
                    cwd=str(Path(__file__).resolve().parent.parent),
                )
            deadline = time.time() + 60
            while time.time() < deadline:
                if marker in log.read_text(errors="replace"):
                    break
                if child.poll() is not None:
                    break
                time.sleep(0.05)
            if then_signal is not None:
                child.send_signal(then_signal)
            try:
                child.wait(timeout=60)
            except Exception:
                child.kill()
                child.wait(timeout=30)
            return child.returncode, log.read_text(errors="replace")

    def test_start_records_pid_and_parent(self) -> None:
        import signal as sig
        _, output = self._run_until("Runtime starting", then_signal=sig.SIGTERM)
        self.assertIn("Runtime starting", output,
                      "a runtime that starts leaves no record of itself")
        self.assertIn(f"ppid={os.getpid()}", output,
                      "the parent is not recorded, so an orphan cannot be told from a child")

    def test_exit_is_recorded(self) -> None:
        import signal as sig
        _, output = self._run_until("Native client runtime active", then_signal=sig.SIGTERM)
        self.assertIn("Runtime exiting", output,
                      "a runtime that stops leaves no record of stopping")


if __name__ == "__main__":
    unittest.main()
