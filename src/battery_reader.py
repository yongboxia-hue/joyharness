"""Joy-Con battery level decoding.

The battery level rides along in byte 2 of the standard 0x30 input report
that RawJoyConReader is already streaming, so there is no separate battery
reader thread: a second component opening the same HID device just fought
the reader for the (exclusive) handle and drained reports out from under
it. This module is now only the pure nibble -> (status, level) decoder.
"""

from __future__ import annotations


def battery_label(nibble: int) -> tuple[str, int]:
    """Return (status_string, level) from Joy-Con's 4-bit power field.

    The protocol reports four discrete levels (plus empty), encoded in the
    even values 0, 2, 4, 6 and 8. The low bit marks charging.
    """
    if not 0x00 <= nibble <= 0x09:
        return ("unknown", -1)
    level = min(nibble >> 1, 4)
    return ("charging" if nibble & 0x01 else "discharging", level)
