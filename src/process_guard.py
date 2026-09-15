"""Keep exactly one runtime alive, and only for as long as the app that owns it.

Both halves of this module exist because of the same day's evidence. The
2026-09-14 crash report shows a runtime whose parent was launchd (pid 1) --
the app that started it had gone, and the orphan kept running for three and a
half hours. Nothing stopped it, and nothing stopped the next launch of the app
from starting a second runtime beside it: that day's log holds 28 process
starts and 823 status-file collisions, which a single runtime cannot produce
because only one thread in it ever writes that file.

An orphan is not merely idle. It keeps enumerating HID every two seconds and
keeps writing the same IPC files as the live runtime, so it competes for the
controller and corrupts the status the UI reads.

The app terminates its child on a clean quit. These guards cover what it
cannot: the app crashing, being force quit, or the user logging out, none of
which run applicationWillTerminate.
"""

from __future__ import annotations

import atexit
import fcntl
import logging
import os
import signal
import sys
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

# Exit code for "another runtime already holds the lock". Distinct from 1 so
# the app can tell a duplicate launch apart from a genuine failure -- and so
# this never reads as a crash in a log.
EXIT_ALREADY_RUNNING = 3

# How often to check whether the parent is still there. Long enough to cost
# nothing, short enough that an orphan cannot outlive the app by much.
_PARENT_POLL_INTERVAL = 2.0


class SingleInstanceLock:
    """An exclusive lock on a file, held for the life of the process.

    flock is used rather than a PID file because the kernel releases it when
    the process dies, however it dies. A PID file would have to be cleaned up
    by the very process that just crashed, and a stale one left behind by a
    SIGKILL would lock out every later launch.
    """

    def __init__(self, path: Path) -> None:
        self._path = path
        self._handle = None

    def acquire(self) -> bool:
        """Take the lock, or return False if another process holds it."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(self._path, "w")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return False
        handle.write(f"{os.getpid()}\n")
        handle.flush()
        self._handle = handle
        return True

    def release(self) -> None:
        if self._handle is None:
            return
        try:
            fcntl.flock(self._handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        self._handle.close()
        self._handle = None

    def __enter__(self) -> "SingleInstanceLock":
        return self

    def __exit__(self, *_exc) -> None:
        self.release()


def watch_parent(stop_event: threading.Event) -> threading.Thread | None:
    """Stop the runtime when the process that launched it goes away.

    macOS has no equivalent of Linux's PR_SET_PDEATHSIG, so this polls: when
    the parent dies the child is reparented to launchd and getppid() starts
    returning 1.

    Returns None when the runtime was already parented to launchd or init at
    startup -- launched from a terminal that has since exited, or run under a
    supervisor. There is no parent to outlive in that case, and treating pid 1
    as "the parent died" would make the runtime quit two seconds in.
    """
    original_parent = os.getppid()
    if original_parent <= 1:
        logger.debug("No owning parent to watch (ppid=%s)", original_parent)
        return None

    def _loop() -> None:
        while not stop_event.wait(_PARENT_POLL_INTERVAL):
            if os.getppid() != original_parent:
                logger.warning(
                    "Parent process %s exited; stopping runtime rather than "
                    "leaving it orphaned",
                    original_parent,
                )
                stop_event.set()
                return

    thread = threading.Thread(target=_loop, name="JoyHarnessParentWatch", daemon=True)
    thread.start()
    return thread


def record_lifecycle() -> None:
    """Log who this process is, and why it stops.

    A runtime killed during startup used to leave exactly one line -- the
    config path -- and nothing else: no exit code, no signal, no parent. Three
    of those in a 2026-09-15 diagnostic package were indistinguishable from a
    runtime that had crashed, hung, or never started, and the actual cause
    (the app terminating it) left no trace at all.

    The handlers go in before the heavy imports on purpose. The runtime
    installs its own once it is running, which supersedes these; until then a
    SIGTERM lands on Python's default handler and dies silently, which is
    exactly the window the three lost processes died in.
    """
    logger.info(
        "Runtime starting: pid=%s ppid=%s python=%s",
        os.getpid(), os.getppid(), sys.version.split()[0],
    )

    def _log_signal(signum, _frame):
        name = signal.Signals(signum).name
        logger.warning(
            "Runtime stopping on %s during startup (pid=%s). Something asked it "
            "to quit before it finished starting -- usually the app restarting it.",
            name, os.getpid(),
        )
        # 128+n is the shell convention for "died on signal n", and what the
        # app sees as the termination status.
        sys.exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _log_signal)

    @atexit.register
    def _log_exit() -> None:
        logger.info("Runtime exiting: pid=%s", os.getpid())
