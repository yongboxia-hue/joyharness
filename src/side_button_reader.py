"""Raw HID readers for Joy-Con input.

pygame/SDL is unreliable for Joy-Con SL/SR on macOS. Holding a raw HID handle
can also make SDL re-enumerate the controller without axes, so macOS uses the
full raw reader below for all buttons and stick input.
"""

from __future__ import annotations

import logging
import threading
import time

from . import hid_access
from .battery_reader import battery_label
from .constants import POLL_INTERVAL, SNAPBACK_FRAMES
from .joystick_handler import apply_deadzone, get_direction

logger = logging.getLogger(__name__)

_VID = 0x057E
_PID_R = 0x2007
_PID_L = 0x2006

_STANDARD_INPUT_REPORT = 0x30

# Subcommand 0x06 sets the Joy-Con's HCI state; 0x00 tells it to disconnect
# and power down. Reading input requires standard report mode 0x30, which
# streams ~60 reports/sec and keeps the radio busy, so a connected Joy-Con
# never idles out on its own -- the only way it sleeps is if we ask it to.
_SUBCMD_SET_HCI_STATE = 0x06
_HCI_STATE_SLEEP = 0x00

# Vibration has to be switched on before any rumble packet does anything.
_SUBCMD_ENABLE_VIBRATION = 0x48

# Output report 0x10 carries rumble and nothing else.
_REPORT_RUMBLE_ONLY = 0x10

# A short, low buzz. Bytes are (high freq, high amp, low freq, low amp) per
# side; this raises amplitude over the neutral pattern without going loud
# enough to be startling in a quiet room.
_BUZZ = bytes([0x00, 0x01, 0x40, 0x60, 0x00, 0x01, 0x40, 0x60])
_SHORT_BUZZ_SECONDS = 0.05
_LONG_BUZZ_SECONDS = 0.25


# How long to leave the device alone after asking it to sleep, so the retry
# loop does not immediately reopen and wake the controller it just put down.
_POST_SLEEP_GRACE = 20.0
_INPUT_REPORT_TIMEOUT = 4.0
# How long a stream that *was* healthy may go silent before we treat the
# handle as dead and reopen (a live Joy-Con streams ~60 reports/sec).
_STALE_REPORT_TIMEOUT = 3.0
_NEUTRAL_RUMBLE = bytes([0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40])

# Standard report 0x30 button bytes (Nintendo's documented layout, mirrored
# across byte 3 for the right controller and byte 5 for the left one; byte 4
# is shared/system buttons regardless of which side is connected):
#   byte 3 (right): Y X B A SR SL R ZR
#   byte 4 (shared): Minus Plus RStick LStick Home Capture - ChargingGrip
#   byte 5 (left):   Down Up Right Left SR SL L ZL
_RIGHT_BUTTON_BITS: dict[str, tuple[int, int]] = {
    "Y": (3, 1 << 0),
    "X": (3, 1 << 1),
    "B": (3, 1 << 2),
    "A": (3, 1 << 3),
    "SR": (3, 1 << 4),
    "SL": (3, 1 << 5),
    "R": (3, 1 << 6),
    "ZR": (3, 1 << 7),
    "Plus": (4, 1 << 1),
    "RStick": (4, 1 << 2),
    "Home": (4, 1 << 4),
}

# Left Joy-Con's own d-pad reuses the right controller's A/B/X/Y names so a
# single mapping schema (and the native MappingEditor UI) works for both
# sides -- positionally aligned with the right controller's diamond layout
# (Up=X/top, Right=A/right, Down=B/bottom, Left=Y/left), per product
# decision: keep left-hand mappings a mirror of the right-hand defaults.
_LEFT_BUTTON_BITS: dict[str, tuple[int, int]] = {
    "B": (5, 1 << 0),   # Down  -> B (bottom), matching right's B
    "X": (5, 1 << 1),   # Up    -> X (top), matching right's X
    "A": (5, 1 << 2),   # Right -> A (right), matching right's A
    "Y": (5, 1 << 3),   # Left  -> Y (left), matching right's Y
    "SR": (5, 1 << 4),
    "SL": (5, 1 << 5),
    "L": (5, 1 << 6),
    "ZL": (5, 1 << 7),
    "Minus": (4, 1 << 0),
    "LStick": (4, 1 << 3),
    "Capture": (4, 1 << 5),
}


class RawJoyConReader:
    """Read a single Joy-Con's inputs directly from standard 0x30 HID reports.

    `side` selects which physical controller to open and how to interpret
    its button/stick bytes -- "R" (default, right Joy-Con) or "L" (left).
    The read loop, dedup/press-release tracking, and key_mapper dispatch are
    identical either way; only the device PID, the button bit table, and
    which half of the report holds the analog stick differ. Each side gets
    its own KeyMapper instance (see runtime.py) reading its own profile, so
    there's no shared button-name namespace to disambiguate here.
    """

    def __init__(
        self,
        stop_event: threading.Event,
        key_mapper,
        config: dict,
        on_input=None,
        side: str = "R",
    ) -> None:
        if side not in ("L", "R"):
            raise ValueError(f"side must be 'L' or 'R', got {side!r}")
        self._side = side
        self._pid = _PID_L if side == "L" else _PID_R
        self._button_bits = _LEFT_BUTTON_BITS if side == "L" else _RIGHT_BUTTON_BITS
        # Standard report 0x30 packs the left stick into bytes 6-8 and the
        # right stick into bytes 9-11, regardless of which single Joy-Con is
        # being read -- each side only ever populates its own half.
        self._stick_byte_offset = 6 if side == "L" else 9
        self._stop_event = stop_event
        self._key_mapper = key_mapper
        self._config = config
        self._on_input = on_input
        self._thread: threading.Thread | None = None
        self._prev_buttons: set[str] = set()
        self._prev_direction: str | None = None
        self._center_count = 0
        self._baseline: tuple[float, float] | None = None
        self._command_counter = 0
        self._connected = threading.Event()
        self._asleep = threading.Event()
        self._buzz_pending = threading.Event()
        self._buzz_long = False
        key_mapper.set_haptic(self.buzz)
        self._battery_lock = threading.Lock()
        self._battery_state: tuple[str, int] = ("unknown", -1)

    @property
    def side(self) -> str:
        return self._side

    @property
    def connected(self) -> bool:
        return self._connected.is_set()

    @property
    def asleep(self) -> bool:
        """True when this side was put to sleep for being idle.

        Distinct from simply disconnected: the controller is fine and will
        come back on the next button press, so the UI should say so rather
        than report it as missing.
        """
        return self._asleep.is_set()

    @property
    def battery_state(self) -> tuple[str, int]:
        with self._battery_lock:
            return self._battery_state

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def join(self, timeout: float = 2.0) -> None:
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=timeout)

    def _open_joycon(self):
        devices = hid_access.enumerate_devices(_VID, self._pid)
        if not devices:
            return None

        try:
            dev = hid_access.open_path(devices[0]["path"])
        except OSError as e:
            logger.debug("Raw Joy-Con HID open failed: %s", e)
            return None

        try:
            self._request_standard_input_report(dev)
            self._write_subcommand(dev, _SUBCMD_ENABLE_VIBRATION, bytes([0x01]))
            return dev
        except OSError as e:
            logger.debug("Raw Joy-Con HID setup failed: %s", e)
            hid_access.close(dev)
            return None

    def _write_subcommand(self, dev, subcommand: int, payload: bytes = b"") -> bool:
        try:
            report = bytes([0x01, self._command_counter & 0x0F]) + _NEUTRAL_RUMBLE \
                + bytes([subcommand]) + payload
            # Joy-Con output reports are a fixed 49 bytes. A short write is
            # accepted by hidapi but may be ignored by the controller.
            report = report.ljust(49, b"\x00")
            self._command_counter = (self._command_counter + 1) & 0x0F
            dev.write(report)
            logger.info("Joy-Con (%s) subcommand 0x%02X sent (%d bytes)",
                        self._side, subcommand, len(report))
            return True
        except OSError as e:
            logger.debug("Raw Joy-Con (%s) subcommand 0x%02X failed: %s", self._side, subcommand, e)
            return False

    def buzz(self, long: bool = False) -> None:
        """Ask for a pulse the next time the read loop comes round.

        Queued rather than sent here because the HID handle belongs to the
        reader thread; KeyMapper runs on it but must not write to the device
        behind the loop's back.

        `long` is the "this is the one that connected" pulse from the
        walkthrough. The long-press tick is deliberately tiny -- you feel it
        through a finger already on the button -- and at that length a
        controller lying in an open hand is easy to miss.
        """
        self._buzz_long = long
        self._buzz_pending.set()

    def _emit_buzz(self, dev) -> None:
        duration = _LONG_BUZZ_SECONDS if self._buzz_long else _SHORT_BUZZ_SECONDS
        try:
            counter = self._command_counter & 0x0F
            self._command_counter = (self._command_counter + 1) & 0x0F
            dev.write(bytes([_REPORT_RUMBLE_ONLY, counter]) + _BUZZ)
            time.sleep(duration)
            counter = self._command_counter & 0x0F
            self._command_counter = (self._command_counter + 1) & 0x0F
            dev.write(bytes([_REPORT_RUMBLE_ONLY, counter]) + _NEUTRAL_RUMBLE)
        except OSError as e:
            logger.debug("Raw Joy-Con (%s) rumble failed: %s", self._side, e)

    def _request_sleep(self, dev) -> bool:
        try:
            report = bytes([0x01, self._command_counter & 0x0F]) + _NEUTRAL_RUMBLE \
                + bytes([_SUBCMD_SET_HCI_STATE, _HCI_STATE_SLEEP])
            self._command_counter = (self._command_counter + 1) & 0x0F
            dev.write(report)
            return True
        except OSError as e:
            logger.info("Raw Joy-Con (%s) sleep request failed: %s", self._side, e)
            return False

    def _request_standard_input_report(self, dev) -> None:
        """Ask Joy-Con R to stream standard 0x30 input reports after reconnect."""
        try:
            report = _build_set_report_mode_command(
                self._command_counter,
                _STANDARD_INPUT_REPORT,
            )
            self._command_counter = (self._command_counter + 1) & 0x0F
            dev.write(report)
            logger.debug("Requested Joy-Con standard input report mode 0x30")
        except OSError as e:
            logger.debug("Joy-Con report-mode request failed: %s", e)

    def _loop(self) -> None:
        while not self._stop_event.is_set():
            self._connected.clear()
            dev = self._open_joycon()
            if dev is None:
                if not self._asleep.is_set():
                    logger.info("Raw Joy-Con (%s) reader waiting for device", self._side)
                self._stop_event.wait(2.0)
                continue

            if self._asleep.is_set():
                # It came back, so a button was pressed on it.
                logger.info("Raw Joy-Con (%s) woke up", self._side)
                self._asleep.clear()

            logger.info("Raw Joy-Con (%s) reader started", self._side)
            try:
                self._read_device(dev)
            except Exception:
                # Anything unexpected in here -- a malformed mapping, the
                # native gateway going away mid-press -- would otherwise
                # escape the loop and kill this side's reader for the life of
                # the process, leaving one controller permanently dead while
                # the other kept working. Log it, reopen, carry on.
                logger.exception("Raw Joy-Con (%s) reader failed; reopening", self._side)
            finally:
                self._connected.clear()
                with self._battery_lock:
                    self._battery_state = ("asleep" if self._asleep.is_set() else "disconnected", -1)
                hid_access.close(dev)
                self._release_all_inputs()
                self._baseline = None
                if self._asleep.is_set():
                    # Leave it alone for a moment: reopening right now would
                    # wake the controller we just put down.
                    self._stop_event.wait(_POST_SLEEP_GRACE)

    def _read_device(self, dev) -> None:
        poll_interval = max(self._config.get("poll_interval", POLL_INTERVAL), 0.001)
        deadzone = self._config.get("deadzone", 0.2)
        stick_mode = self._config.get("stick_mode", "4dir")
        last_report_at = time.monotonic()
        last_activity_at = time.monotonic()
        saw_standard_report = False

        while not self._stop_event.is_set():
            try:
                data = dev.read(64, timeout_ms=50)
            except OSError as e:
                logger.info("Raw Joy-Con (%s) read failed (%s); reopening", self._side, e)
                return

            if data and len(data) >= 12 and data[0] == 0x30:
                if not saw_standard_report:
                    logger.info("Raw Joy-Con (%s) standard input reports active", self._side)
                    saw_standard_report = True
                    self._connected.set()
                last_report_at = time.monotonic()
                if self._handle_buttons(data) | self._handle_stick(data, deadzone, stick_mode):
                    last_activity_at = last_report_at
                self._handle_battery(data)

                # Read fresh each time rather than once at loop start: the
                # setting is a toggle in the UI, and reload_config swaps the
                # values in this same dict. Caching it would mean the switch
                # did nothing until the controller happened to reconnect.
                idle_sleep = max(float(self._config.get("idle_sleep_minutes", 0) or 0), 0) * 60.0

                # Idle is measured from the last real input, not the last
                # report: in 0x30 mode reports never stop arriving.
                if idle_sleep and last_report_at - last_activity_at > idle_sleep:
                    logger.info(
                        "Raw Joy-Con (%s) idle for %s; asking it to sleep",
                        self._side,
                        f"{idle_sleep / 60.0:.0f} min" if idle_sleep >= 60 else f"{idle_sleep:.0f}s",
                    )
                    if self._request_sleep(dev):
                        self._asleep.set()
                    return
            else:
                # A Joy-Con in 0x30 mode streams ~60 reports/sec whether or not
                # anything is being pressed, so *any* real gap means the link is
                # gone. macOS hidapi does not raise when a Bluetooth Joy-Con
                # sleeps or drops: read() just returns empty forever. Without
                # this check the loop spins on a dead handle indefinitely --
                # still reporting "connected", still holding the device open so
                # neither this reader nor anything else could reclaim it, which
                # is exactly how a controller went permanently unresponsive
                # while the UI kept showing it as connected.
                timeout = _STALE_REPORT_TIMEOUT if saw_standard_report else _INPUT_REPORT_TIMEOUT
                if time.monotonic() - last_report_at > timeout:
                    logger.info(
                        "Raw Joy-Con (%s) sent no input reports for %.0fs; closing and reopening",
                        self._side,
                        timeout,
                    )
                    return

            if self._buzz_pending.is_set():
                self._buzz_pending.clear()
                self._emit_buzz(dev)

            self._key_mapper.poll()
            time.sleep(poll_interval)

    def _handle_battery(self, data: list[int]) -> None:
        power_nibble = (data[2] >> 4) & 0x0F
        state = battery_label(power_nibble)
        with self._battery_lock:
            self._battery_state = state

    def _handle_buttons(self, data: list[int]) -> bool:
        """Dispatch button changes; returns True if anything actually changed."""
        current = _extract_buttons(data, self._button_bits)
        pressed = current - self._prev_buttons
        released = self._prev_buttons - current

        for name in sorted(pressed):
            logger.debug("raw button DOWN: %s", name)
            self._emit_input(name, "down")
            self._key_mapper.button_down_name(name)

        for name in sorted(released):
            logger.debug("raw button UP: %s", name)
            self._emit_input(name, "up")
            self._key_mapper.button_up_name(name)

        self._prev_buttons = current
        return bool(pressed or released)

    def _emit_input(self, button: str, phase: str) -> None:
        if self._on_input is not None:
            try:
                self._on_input(button, phase)
            except Exception:
                logger.debug("Input event observer failed", exc_info=True)

    def _handle_stick(self, data: list[int], deadzone: float, stick_mode: str) -> bool:
        """Dispatch stick movement; returns True if the direction changed."""
        x, y = _extract_stick(data, self._stick_byte_offset)
        if self._baseline is None:
            self._baseline = (x, y)
            logger.info("Raw stick baseline: x=%.1f, y=%.1f", x, y)
            return False

        base_x, base_y = self._baseline
        raw_x = (x - base_x) / 2048.0
        raw_y = -(y - base_y) / 2048.0
        filt_x, filt_y = apply_deadzone(raw_x, raw_y, deadzone)
        direction = get_direction(filt_x, filt_y, stick_mode)

        if direction != self._prev_direction:
            if direction is None:
                self._center_count += 1
                if self._center_count >= SNAPBACK_FRAMES:
                    self._key_mapper.stick_centered()
                    self._prev_direction = None
                    return True
            else:
                self._center_count = 0
                self._key_mapper.stick_direction(direction)
                self._prev_direction = direction
                return True
        return False

    def _release_all_inputs(self) -> None:
        for name in sorted(self._prev_buttons):
            self._emit_input(name, "up")
            self._key_mapper.button_up_name(name)
        self._prev_buttons.clear()
        self._prev_direction = None
        self._center_count = 0
        self._key_mapper.release_all()


def _extract_buttons(data: list[int], button_bits: dict[str, tuple[int, int]]) -> set[str]:
    result: set[str] = set()
    for name, (byte_idx, mask) in button_bits.items():
        if len(data) > byte_idx and data[byte_idx] & mask:
            result.add(name)
    return result


def _extract_stick(data: list[int], byte_offset: int) -> tuple[int, int]:
    """Unpack a 12-bit-per-axis analog stick starting at `byte_offset`
    (6 for the left stick, 9 for the right one) in a standard 0x30 report."""
    lo, mid, hi = data[byte_offset], data[byte_offset + 1], data[byte_offset + 2]
    x = lo | ((mid & 0x0F) << 8)
    y = (mid >> 4) | (hi << 4)
    return x, y


def _build_set_report_mode_command(counter: int, report_mode: int) -> bytes:
    """Build Joy-Con subcommand 0x03, which selects the input report mode."""
    return bytes([0x01, counter & 0x0F]) + _NEUTRAL_RUMBLE + bytes([0x03, report_mode])
