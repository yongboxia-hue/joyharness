"""System key-repeat settings and modifier classification.

A Joy-Con button in passthrough mode is meant to feel exactly like the
keyboard key it stands for, and the part of that users notice most is what
happens when they hold it down. macOS does not auto-repeat synthetic key
events, so the repeats have to be produced here -- but the timing is not
ours to invent: it is read from the user's own keyboard preferences, so a
held button repeats at the rate their keyboard already repeats at and
there is nothing new to explain or configure.

Adjusting it is done where it has always been done: System Settings ->
Keyboard -> Key repeat rate / Delay until repeat.
"""

from __future__ import annotations

import logging
import subprocess
import time

logger = logging.getLogger(__name__)

# macOS stores both preferences as a count of 15ms units -- the same unit
# System Settings' sliders move in, so a value of 2 means 30ms.
_UNIT_SECONDS = 0.015

# What macOS itself uses when the preference was never written.
_DEFAULT_INITIAL_UNITS = 25   # 375ms before the first repeat
_DEFAULT_REPEAT_UNITS = 6     # 90ms between repeats after that

# Keys that are held rather than repeated. A keyboard does not machine-gun
# a modifier when you hold it -- it just stays down -- so neither do we.
MODIFIERS: frozenset[str] = frozenset({
    "cmd", "cmd_l", "cmd_r",
    "ctrl", "ctrl_l", "ctrl_r",
    "alt", "alt_l", "alt_r",
    "shift", "shift_l", "shift_r",
    "fn", "caps_lock",
})


def is_modifier(key: str) -> bool:
    return key.lower() in MODIFIERS


def _read_units(preference: str, fallback: int) -> int:
    try:
        raw = subprocess.run(
            ["defaults", "read", "-g", preference],
            capture_output=True, text=True, timeout=2.0,
        )
    except (OSError, subprocess.SubprocessError):
        return fallback
    if raw.returncode != 0:
        # Never written, which means the system is using its own default.
        return fallback
    try:
        units = float(raw.stdout.strip())
    except ValueError:
        return fallback
    return int(units) if units > 0 else fallback


_cache: tuple[float, tuple[float, float]] | None = None
_CACHE_SECONDS = 30.0


def system_key_repeat() -> tuple[float, float]:
    """(delay before the first repeat, interval between repeats), in seconds.

    Cached briefly: each side builds a KeyMapper and each config save rebuilds
    both, so an uncached lookup spawns four `defaults` processes every time the
    user edits a mapping. Thirty seconds is short enough that changing the
    system setting still takes effect while the user is still looking at it.
    """
    global _cache
    if _cache is not None and time.monotonic() - _cache[0] < _CACHE_SECONDS:
        return _cache[1]
    value = _read_system_key_repeat()
    _cache = (time.monotonic(), value)
    return value


def _read_system_key_repeat() -> tuple[float, float]:
    initial = _read_units("InitialKeyRepeat", _DEFAULT_INITIAL_UNITS)
    interval = _read_units("KeyRepeat", _DEFAULT_REPEAT_UNITS)
    delay_s = initial * _UNIT_SECONDS
    interval_s = interval * _UNIT_SECONDS
    logger.info(
        "Key repeat follows system settings: first repeat after %.0fms, then every %.0fms",
        delay_s * 1000, interval_s * 1000,
    )
    return delay_s, interval_s
