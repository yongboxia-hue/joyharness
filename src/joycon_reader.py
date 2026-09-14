"""Which Joy-Cons are paired, asked over raw HID.

This used to go through pygame/SDL, which meant the bundled runtime carried
SDL2 and its whole media stack -- image, mixer, ttf, FLAC, fluidsynth,
freetype and the rest -- about 31MB per architecture, and the app ships two.
All of that to log one line at startup saying what was paired.

Nothing else needed it. The input loop has always read raw HID
(side_button_reader.RawJoyConReader), and the connection mode reported in
status.json is derived from those readers, not from here.
"""

from __future__ import annotations

import logging

from . import hid_access

logger = logging.getLogger(__name__)

# Nintendo's vendor id, and the product ids for each Joy-Con half. Kept in
# step with side_button_reader, which reads from the same devices.
_VID = 0x057E
_PID_LEFT = 0x2006
_PID_RIGHT = 0x2007

_SIDE_NAMES = {_PID_LEFT: "Joy-Con (L)", _PID_RIGHT: "Joy-Con (R)"}


def connected_controllers() -> list[str]:
    """Names of the Joy-Cons currently paired, for the startup log.

    Purely descriptive. An empty list means none are paired *right now*,
    which is not a problem: the readers wait for a device and pick it up
    whenever it appears.
    """
    found: list[str] = []
    for product_id, label in _SIDE_NAMES.items():
        try:
            devices = hid_access.enumerate_devices(_VID, product_id)
        except Exception:
            logger.debug("HID enumerate failed for %04X", product_id, exc_info=True)
            continue
        for device in devices:
            # The OS-reported name is the useful one when it exists; some
            # pairings report an empty product string, hence the fallback.
            name = (device.get("product_string") or "").strip() or label
            found.append(name)
    return found
