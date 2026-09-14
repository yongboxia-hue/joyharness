"""Serialised access to hidapi.

hidapi keeps process-global state on macOS -- the IOHIDManager and the list of
open devices -- and its own documentation says init and exit are not thread
safe. The Python binding releases the GIL around every call (the extension
imports PyEval_SaveThread), so several of our threads genuinely execute inside
that C code at the same time rather than being serialised by the interpreter.

The left and right side-button readers each enumerate every two seconds, on
their own threads, and keep-alive enumerates and opens on top of them whenever
it is switched on. Until this module existed, nothing coordinated them.

That is what killed the runtime on the 2026-09-14 company machine: SIGABRT
raised by libsystem_malloc, reported from inside hid_init, after three and a
half hours of both readers enumerating on the same second. An abort out of
malloc is the heap being corrupted -- not a HID error, and not something the
calling Python code could have caught.

Reads stay outside the lock on purpose. Each open device is read from exactly
one thread, which hidapi does support, and a read blocks for up to the poll
interval; holding a process-wide lock across it would serialise the two
controllers and add latency to every button press. What is serialised here is
the global-state work: enumerate, open, close.
"""

from __future__ import annotations

import logging
import threading

import hid

logger = logging.getLogger(__name__)

# Re-entrant so that a helper here can call another one without deadlocking.
_LOCK = threading.RLock()


def enumerate_devices(vendor_id: int, product_id: int) -> list[dict]:
    """List attached devices. Serialised against every other hidapi call."""
    with _LOCK:
        return hid.enumerate(vendor_id, product_id)


def open_path(path: bytes):
    """Open a device by path, or raise OSError.

    Creating the handle and opening it are one operation here so a caller
    cannot leave a half-open handle outside the lock. If the open fails the
    handle is closed before the lock is released, because an abandoned handle
    is exactly the kind of thing that corrupts hidapi's device list later.
    """
    with _LOCK:
        device = hid.device()
        try:
            device.open_path(path)
        except BaseException:
            try:
                device.close()
            except Exception:
                pass
            raise
        return device


def close(device) -> None:
    """Close a device handle. Never raises."""
    if device is None:
        return
    with _LOCK:
        try:
            device.close()
        except Exception:
            logger.debug("HID close failed", exc_info=True)
