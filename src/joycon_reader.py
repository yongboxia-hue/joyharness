"""pygame-based Joy-Con discovery.

The actual input loop lives in side_button_reader.RawJoyConReader (raw
HID, not pygame/SDL -- see that module's docstring for why). This module
is only pygame's joystick *enumeration*: detecting which Joy-Con(s) are
paired and their connection mode, used at startup and by --discover for
calibration.
"""

from __future__ import annotations

import logging

import pygame

from .constants import BUTTON_NAMES, BUTTON_NAMES_BY_MODE

logger = logging.getLogger(__name__)


def find_joycon(joystick_index: int | None = None) -> pygame.joystick.Joystick | None:
    """Find and return a Joy-Con joystick instance.

    Args:
        joystick_index: Specific device index to use. None for auto-detection.

    Returns:
        pygame Joystick instance, or None if not found.
    """
    pygame.joystick.init()
    count = pygame.joystick.get_count()

    if count == 0:
        return None

    logger.info("Found %d joystick(s)", count)

    if joystick_index is not None:
        if 0 <= joystick_index < count:
            js = pygame.joystick.Joystick(joystick_index)
            logger.info("Using joystick #%d: %s", joystick_index, js.get_name())
            return js
        logger.error("Joystick index %d out of range (0-%d)", joystick_index, count - 1)
        return None

    # Auto-detect: look for Joy-Con in device names (accept both L and R)
    for i in range(count):
        js = pygame.joystick.Joystick(i)
        name = js.get_name().lower()
        logger.info("  [%d] %s (buttons=%d, axes=%d)",
                     i, js.get_name(), js.get_numbuttons(), js.get_numaxes())

        if "joy-con" in name or "joy con" in name or "switch" in name or "pro controller" in name:
            logger.info("Auto-selected joystick [%d]: %s", i, js.get_name())
            return js

    # Fallback: if only one joystick, use it
    if count == 1:
        js = pygame.joystick.Joystick(0)
        logger.info("Single joystick found, using: %s", js.get_name())
        return js

    logger.warning("No Joy-Con detected among %d joysticks", count)
    return None


def detect_connection_mode() -> str:
    """Detect the Joy-Con connection mode from connected joysticks.

    Scans all connected pygame joysticks and determines whether only a
    left Joy-Con, only a right Joy-Con, or both (dual/combined) are connected.

    Returns:
        One of "single_left", "single_right", or "dual".
    """
    count = pygame.joystick.get_count()

    if count == 0:
        return "single_right"

    has_left = False
    has_right = False

    for i in range(count):
        js = pygame.joystick.Joystick(i)
        name = js.get_name().lower()

        # Skip non-Joy-Con devices
        if not any(kw in name for kw in ("joy-con", "joy con", "switch", "pro controller")):
            continue

        # Check for combined device (contains both "l" and "r")
        if "l" in name and "r" in name:
            logger.debug("Detected combined Joy-Con device: %s", js.get_name())
            return "dual"

        if "l" in name:
            has_left = True
        elif "r" in name:
            has_right = True
        else:
            # Unidentified side — check number of buttons as heuristic
            # Combined devices typically have 20+ buttons
            if js.get_numbuttons() >= 18:
                logger.debug("Detected combined Joy-Con device (high button count): %s", js.get_name())
                return "dual"
            # Default to right if single device
            has_right = True

    if has_left and has_right:
        logger.debug("Detected both L and R Joy-Cons (separate devices)")
        return "dual"
    elif has_left:
        logger.debug("Detected single left Joy-Con")
        return "single_left"
    else:
        logger.debug("Detected single right Joy-Con")
        return "single_right"


def run_discover_mode(joystick_index: int | None = None) -> None:
    """Run discovery mode: print raw button/axis values for calibration.

    Press Ctrl+C to exit. Use this to determine correct button indices
    for your specific controller/driver combination.
    """
    pygame.init()
    js = find_joycon(joystick_index)

    if js is None:
        print("No joystick found. Make sure your Joy-Con R is connected via Bluetooth.")
        print("Tip: Windows Settings → Bluetooth → Add device → hold the small pairing")
        print("     button on the Joy-Con rail for 3 seconds until lights flash.")
        pygame.quit()
        return

    # Use mode-aware button names for discover output
    mode = detect_connection_mode()
    btn_names = BUTTON_NAMES_BY_MODE.get(mode, BUTTON_NAMES)

    print(f"\n=== Discovery Mode ===")
    print(f"Controller: {js.get_name()}")
    print(f"GUID: {js.get_guid()}")
    print(f"Buttons: {js.get_numbuttons()}")
    print(f"Axes: {js.get_numaxes()}")
    print(f"Connection mode: {mode}")
    print(f"\nPress buttons and move sticks to see their indices.")
    print(f"Press Ctrl+C to exit.\n")

    clock = pygame.time.Clock()
    prev_buttons: set[int] = set()

    try:
        while True:
            pygame.event.pump()

            current_buttons: set[int] = set()
            for i in range(js.get_numbuttons()):
                if js.get_button(i):
                    current_buttons.add(i)

            pressed = current_buttons - prev_buttons
            released = prev_buttons - current_buttons

            for i in sorted(pressed):
                name = btn_names.get(i, "???")
                print(f"  BTN {i:2d} ({name:8s}) PRESSED")

            for i in sorted(released):
                name = btn_names.get(i, "???")
                print(f"  BTN {i:2d} ({name:8s}) released")

            prev_buttons = current_buttons

            # Axis state (only print if changed significantly)
            for i in range(js.get_numaxes()):
                val = js.get_axis(i)
                if abs(val) > 0.1:
                    print(f"  AXIS {i}: {val:+.3f}", end="\r")

            clock.tick(60)

    except KeyboardInterrupt:
        print("\nDiscovery mode ended.")
    finally:
        pygame.quit()


