"""NS Joy-Con Keyboard Mapper — CLI entry point.

Maps Nintendo Switch Joy-Con controller inputs to keyboard shortcuts.
Supports configurable key mappings via JSON config files. macOS only.

Usage:
    python -m src                    # Run with default mappings
    python src/main.py               # Also supported
    python -m src --discover         # Calibrate button indices
    python -m src --config my.json   # Use custom config
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

# Ensure the project root is on sys.path so that `src` is importable
# as a package when running `python src/main.py` directly.
if __package__ is None:
    _project_root = str(Path(__file__).resolve().parent.parent)
    if _project_root not in sys.path:
        sys.path.insert(0, _project_root)
    __package__ = "src"

# Prevent SDL2 from merging Joy-Con L+R into a single combined device.
# Without this, SDL2 exclusively consumes Joy-Con R's HID report stream,
# making it impossible for the battery reader to receive any reports from R.
# With this set, both Joy-Cons remain independent Joystick devices and
# hidapi can concurrently read battery reports from each one.
os.environ.setdefault("SDL_JOYSTICK_HIDAPI_COMBINE_JOY_CONS", "0")

# macOS: prevent SDL2 from installing its NSApplication subclass.
# SDLApplication doesn't implement -macOSVersion, which Tk 9.0+ calls,
# causing a crash on GUI startup. We don't need video — only joystick —
# so the dummy video driver is safe and avoids the Cocoa hook.
if sys.platform == "darwin":
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")

from .config_loader import GESTURE_SLOTS, load_config, get_platform_config_path
from .constants import DEFAULT_LONG_PRESS_THRESHOLD
from .platform.permission import (
    get_permission_warning,
    has_required_permissions,
    request_required_permissions,
)

logger = logging.getLogger(__name__)


def list_controls(config: dict) -> None:
    """Print both controllers' mappings.

    There is no single "active" profile -- the left controller always
    runs its own mappings and the right controller always runs its own,
    independent of which (or how many) are actually connected, so both
    are printed unconditionally rather than picking one.
    """
    from .config_loader import get_profile
    from .constants import MODE_LABELS

    for mode in ("single_right", "single_left"):
        label = MODE_LABELS.get(mode, mode)
        print(f"\n=== {label} ({mode}) ===")
        _print_profile_mappings(get_profile(config, mode).get("mappings", {}), config)

    print(f"\nDeadzone: {config.get('deadzone', 0.15)}")
    print(f"Long press: {config.get('long_press_threshold', DEFAULT_LONG_PRESS_THRESHOLD)}s")
    print(f"Stick mode: {config.get('stick_mode', '4dir')}")
    print(f"Poll interval: {config.get('poll_interval', 0.01) * 1000:.0f}ms")


def _print_profile_mappings(mappings: dict, config: dict) -> None:
    """Print one profile the way the mapping editor shows it.

    Every line comes from the same three shapes config_loader validates --
    passthrough, a gesture split, or a built-in -- so a mapping this printer
    cannot describe is a mapping the config would have rejected. The previous
    version still spoke the pre-passthrough vocabulary (tap/combination and a
    scalar "key" field) and printed a bare "?" for fifteen of the sixteen
    mappings in the shipped config, including every default one.
    """
    default_threshold = config.get("long_press_threshold", DEFAULT_LONG_PRESS_THRESHOLD)

    print("\n--- Button Mappings ---")
    for btn_name, mapping in mappings.get("buttons", {}).items():
        action = mapping["action"]
        print(f"  {btn_name:8s} [{action:14s}] → {_describe_mapping(mapping, config, default_threshold)}")

    print("\n--- Stick Direction Mappings ---")
    for direction, mapping in mappings.get("stick_directions", {}).items():
        action = mapping["action"]
        print(f"  {direction:8s} [{action:14s}] → {_describe_mapping(mapping, config, default_threshold)}")


def _describe_mapping(mapping: dict, config: dict, default_threshold: float) -> str:
    """One line for a whole button: its keys, its gesture slots, or its built-in."""
    action = mapping.get("action")

    if action == "passthrough":
        return "+".join(mapping.get("keys", [])) + " (held; repeats at the system rate)"

    if action in GESTURE_SLOTS:
        threshold = mapping.get("threshold", default_threshold)
        timeout = mapping.get("timeout", config.get("double_tap_timeout", 0.35))
        parts = [
            f"{slot}={_format_inline_mapping(mapping[slot])}"
            for slot in GESTURE_SLOTS[action]
            if isinstance(mapping.get(slot), dict)
        ]
        if action == "double_tap":
            parts.append(f"timeout={timeout:.2f}s")
        else:
            parts.append(f"threshold={threshold:.2f}s")
        return ", ".join(parts)

    return _BUILT_IN_SUMMARIES.get(action, action or "?")


# What a built-in does at each of its levels. Keep in step with key_mapper's
# dispatch and with MappingConfigReader.rows(for:) on the native side.
_BUILT_IN_SUMMARIES = {
    "app_switch_mode": "short=cmd+tab, long=locked switcher",
    "window_switch": "cycle the configured app's windows",
    "window_picker": "open the window picker",
    "focus_input": "move the caret into the frontmost window's text input",
    "screenshot": "short=capture+paste, long=capture",
    "disabled": "(not set)",
}


def _format_inline_mapping(mapping: dict) -> str:
    """Format one gesture slot -- a set of keys, or a built-in."""
    keys = mapping.get("keys")
    if keys:
        return "+".join(keys)
    action = mapping.get("action")
    return _BUILT_IN_SUMMARIES.get(action, action or "?")


def build_parser() -> argparse.ArgumentParser:
    """Build CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="NS Joy-Con Keyboard Mapper — Map controller buttons to keyboard shortcuts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python src/main.py --discover       # Calibrate button indices first
  python src/main.py                  # Run with default mappings
  python src/main.py --config custom.json  # Use custom config
  python src/main.py --deadzone 0.2   # Override deadzone
  python src/main.py --list-controls  # Show current mappings
        """,
    )

    parser.add_argument(
        "--config", "-c",
        type=str,
        default=None,
        help="Path to JSON config file (default: built-in defaults)",
    )
    parser.add_argument(
        "--discover", "-d",
        action="store_true",
        help="Discovery mode: print raw button/axis values for calibration",
    )
    parser.add_argument(
        "--deadzone",
        type=float,
        default=None,
        help="Override deadzone value (0.0 to 0.99)",
    )
    parser.add_argument(
        "--joystick", "-j",
        type=int,
        default=None,
        help="Specific joystick device index to use",
    )
    parser.add_argument(
        "--list-controls", "-l",
        action="store_true",
        help="List all control names and current mappings, then exit",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable debug logging",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"JoyHarness {__import__('src.constants', fromlist=['__version__']).__version__}",
    )
    parser.add_argument(
        "--no-admin-warn",
        action="store_true",
        help="Suppress administrator/permission warning",
    )
    parser.add_argument(
        "--native-client",
        action="store_true",
        help="Run as the headless Joy-Con service owned by the native macOS App.",
    )

    return parser


def _get_pairing_instructions() -> str:
    """Return Joy-Con pairing instructions."""
    return (
        "\nPairing instructions (macOS):\n"
        "  1. System Settings → Bluetooth\n"
        "  2. Hold the small pairing button on the Joy-Con rail for 3 seconds\n"
        "  3. Lights will flash rapidly — select 'Joy-Con (R)' or 'Joy-Con (L)' in Bluetooth list\n"
        "  4. Run --discover to verify connection"
    )


def main() -> None:
    """Main entry point."""
    parser = build_parser()
    args = parser.parse_args()

    # Setup logging
    log_level = logging.DEBUG if args.verbose else logging.INFO
    handlers: list[logging.Handler] = [
        logging.StreamHandler(),
    ]
    if args.verbose:
        log_path = Path(__file__).resolve().parent.parent / "nsjc.log"
        handlers.append(logging.FileHandler(log_path, encoding="utf-8"))
    # The pid and the date are both here because the app appends every
    # runtime's output to one file that is never rotated. Diagnosing the
    # 2026-09-14 crash meant separating two code versions and several
    # processes out of 181k undated lines that all looked alike.
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [pid %(process)d] [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers,
    )

    # Permission check
    if not args.native_client and not args.no_admin_warn and not has_required_permissions():
        print(get_permission_warning())
        request_required_permissions()

    # Load config — prefer platform-specific user config if it exists
    config_path = args.config
    if config_path is None:
        config_path = get_platform_config_path()
    try:
        config = load_config(config_path)
    except (FileNotFoundError, ValueError) as e:
        print(f"Config error: {e}")
        sys.exit(1)

    # Override deadzone if specified
    if args.deadzone is not None:
        if not 0.0 <= args.deadzone < 1.0:
            print(f"Invalid deadzone: {args.deadzone} (must be 0.0 to 0.99)")
            sys.exit(1)
        config["deadzone"] = args.deadzone

    # List controls mode
    if args.list_controls:
        list_controls(config)
        return

    # Discover mode
    if args.discover:
        from .joycon_reader import run_discover_mode

        run_discover_mode(args.joystick)
        return

    from .process_guard import EXIT_ALREADY_RUNNING, SingleInstanceLock
    from .runtime import JoyHarnessRuntime
    from .runtime_ipc import IPC_DIR

    # Two runtimes on one IPC directory fight over the controller and over
    # status.json, and the loser's writes land in the UI. The lock is scoped
    # to the IPC directory, so a development instance pointed at its own
    # JOYHARNESS_IPC_DIR still starts alongside the installed app.
    instance_lock = SingleInstanceLock(IPC_DIR / "runtime.lock")
    if not instance_lock.acquire():
        logging.getLogger(__name__).error(
            "Another JoyHarness runtime is already using %s; exiting.", IPC_DIR
        )
        sys.exit(EXIT_ALREADY_RUNNING)

    try:
        runtime = JoyHarnessRuntime(
            config,
            joystick_index=args.joystick,
            pairing_instructions=_get_pairing_instructions,
            config_path=config_path,
        )
        runtime.run()
    finally:
        instance_lock.release()


if __name__ == "__main__":
    main()
