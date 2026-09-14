"""Configuration loading, validation and saving.

Single source of truth: the JSON config file. What is in the file is
exactly what runs -- there is no second, compiled-in copy of the mappings
merged underneath it, and no per-profile fallback. A config that is
missing or malformed fails loudly at startup instead of quietly running
something the mapping editor never showed the user.

The file the native app runs against lives in its Application Support
directory; config/user.json in the repo is what gets shipped into the app
bundle and installed there on first run (and re-installed when the file's
own `config_version` is raised -- see RuntimeManager.prepareDataDirectory).
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path

from .constants import (
    BUTTON_NAMES,
    BUTTON_NAMES_BY_MODE,
    DEFAULT_LONG_PRESS_THRESHOLD,
    STICK_DIRECTIONS,
)

logger = logging.getLogger(__name__)


_CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"
USER_CONFIG_PATH = str(_CONFIG_DIR / "user.json")

# Profiles every config file must define -- one per physical controller.
# Each side always runs its own; neither is ever substituted for the other.
REQUIRED_PROFILES = ("single_right", "single_left")


def get_platform_config_path() -> str:
    """Path of the shipped config file (config/user.json)."""
    return USER_CONFIG_PATH


def load_config(path: str | None = None) -> dict:
    """Load and validate a configuration file.

    Args:
        path: Path to the JSON config file. None uses the shipped
            config/user.json.

    Returns:
        The configuration exactly as written in the file.

    Raises:
        FileNotFoundError: The config file does not exist.
        json.JSONDecodeError: The config file is not valid JSON.
        ValueError: The config file is missing or misdeclares mappings.
    """
    config_path = Path(path) if path is not None else Path(USER_CONFIG_PATH)
    if not config_path.exists():
        raise FileNotFoundError(f"Config file not found: {config_path}")

    with open(config_path, encoding="utf-8") as f:
        config = json.load(f)

    errors = validate_config(config)
    if errors:
        raise ValueError(
            f"Invalid configuration in {config_path}:\n"
            + "\n".join(f"  - {e}" for e in errors)
        )

    logger.info("Loaded config from: %s", config_path)
    return config


def get_profile(config: dict, mode: str) -> dict:
    """Return the mapping profile for one controller side.

    No fallback: if a side's profile is missing the config is broken, and
    silently running the *other* side's mappings is exactly the behaviour
    that made the app disagree with its own mapping editor. load_config
    already rejects such a file, so reaching the raise means the dict was
    built by hand.
    """
    try:
        return config["profiles"][mode]
    except (KeyError, TypeError):
        raise KeyError(
            f"Config has no '{mode}' profile; expected one per side: "
            + ", ".join(REQUIRED_PROFILES)
        ) from None


def validate_config(config: dict) -> list[str]:
    """Validate configuration and return list of error strings.

    Empty list means valid configuration.

    Checks:
    - Deadzone is within [0.0, 0.99]
    - Stick mode is "4dir" or "8dir"
    - Every action type is valid
    - Every key name is recognized by the keyboard library
    - Both side profiles exist and are *complete*: every button and the
      four stick directions are declared. Completeness is what makes the
      file the single source of truth -- an absent entry used to be
      silently filled in from a compiled-in default, so the app ran
      mappings the editor never showed.
    """
    errors: list[str] = []

    # Top-level validation
    deadzone = config.get("deadzone", 0.15)
    if not isinstance(deadzone, (int, float)) or not (0.0 <= deadzone < 1.0):
        errors.append(f"deadzone must be between 0.0 and 0.99, got {deadzone}")

    stick_mode = config.get("stick_mode", "4dir")
    if stick_mode not in ("4dir", "8dir"):
        errors.append(f"stick_mode must be '4dir' or '8dir', got '{stick_mode}'")

    idle_sleep = config.get("idle_sleep_minutes", 0)
    if not isinstance(idle_sleep, (int, float)) or idle_sleep < 0:
        errors.append(f"idle_sleep_minutes must be 0 or a positive number, got {idle_sleep}")

    poll_interval = config.get("poll_interval", 0.01)
    if not isinstance(poll_interval, (int, float)) or poll_interval <= 0:
        errors.append(f"poll_interval must be a positive number, got {poll_interval}")

    double_tap_timeout = config.get("double_tap_timeout", 0.35)
    if not isinstance(double_tap_timeout, (int, float)) or double_tap_timeout <= 0:
        errors.append(f"double_tap_timeout must be a positive number, got {double_tap_timeout}")

    long_press_threshold = config.get("long_press_threshold", DEFAULT_LONG_PRESS_THRESHOLD)
    if not isinstance(long_press_threshold, (int, float)) or long_press_threshold <= 0:
        errors.append(
            f"long_press_threshold must be a positive number, got {long_press_threshold}"
        )

    profiles = config.get("profiles")
    if not isinstance(profiles, dict):
        errors.append("Config must define a 'profiles' object")
        return errors

    for mode in REQUIRED_PROFILES:
        profile = profiles.get(mode)
        if not isinstance(profile, dict):
            errors.append(f"Missing '{mode}' profile")
            continue

        btn_names = set(BUTTON_NAMES_BY_MODE.get(mode, BUTTON_NAMES).values())
        mappings = profile.get("mappings", {})
        buttons = mappings.get("buttons", {})
        sticks = mappings.get("stick_directions", {})

        for missing in sorted(btn_names - set(buttons)):
            errors.append(f"[{mode}] Missing mapping for button '{missing}'")
        for btn_name, mapping in buttons.items():
            if btn_name not in btn_names:
                errors.append(f"[{mode}] Unknown button name: '{btn_name}'")
                continue
            errors.extend(_validate_mapping_entry(f"[{mode}] {btn_name}", mapping))

        for missing in sorted({"up", "down", "left", "right"} - set(sticks)):
            errors.append(f"[{mode}] Missing mapping for stick direction '{missing}'")
        for dir_name, mapping in sticks.items():
            if dir_name not in STICK_DIRECTIONS:
                errors.append(f"[{mode}] Unknown stick direction: '{dir_name}'")
                continue
            errors.extend(_validate_mapping_entry(f"[{mode}] {dir_name}", mapping))

    return errors


# Built-in actions whose two levels are part of the action itself rather
# than something the user configures (tap switches, hold opens a chooser).
BUILT_IN_ACTIONS = ("window_switch", "app_switch_mode", "focus_input", "screenshot", "window_picker")

# Actions that split one button into several, by how long or how often it
# is pressed. Each named slot holds one discrete action.
GESTURE_SLOTS: dict[str, tuple[str, ...]] = {
    "short_long": ("short", "long"),
    "double_tap": ("single", "double"),
    "multi_trigger": ("tap", "double", "hold"),
}


def _validate_mapping_entry(name: str, mapping: dict) -> list[str]:
    """Validate one button or stick-direction mapping.

    A mapping is exactly one of three things, and its shape says which:

    - passthrough: the button *is* the key. Modifiers stay down while it is
      held and the rest repeats, exactly like the keyboard key it stands for.
    - a gesture split (short_long / double_tap / multi_trigger): each named
      slot holds one discrete action.
    - a built-in whose two levels are fixed.

    `repeat` is rejected everywhere. How a held key repeats comes from the
    user's own System Settings, so a value here would be ignored and would
    then disagree with what the app actually does.
    """
    errors: list[str] = []
    if not isinstance(mapping, dict):
        return [f"'{name}' mapping must be a dict, got {type(mapping).__name__}"]

    if "repeat" in mapping:
        errors.append(
            f"'{name}' sets 'repeat'; key repeat follows System Settings and "
            f"cannot be set per key"
        )

    action = mapping.get("action")

    if action == "passthrough":
        errors.extend(_validate_keys(name, mapping.get("keys")))
        return errors

    if action in GESTURE_SLOTS:
        # Absent means "use the profile's long_press_threshold"; only a button
        # that deliberately differs carries its own number.
        threshold = mapping.get("threshold", DEFAULT_LONG_PRESS_THRESHOLD)
        if not isinstance(threshold, (int, float)) or threshold <= 0:
            errors.append(f"'{name}' threshold must be a positive number, got {threshold}")
        slots = GESTURE_SLOTS[action]
        if not any(isinstance(mapping.get(slot), dict) for slot in slots):
            errors.append(f"'{name}' action '{action}' needs at least one of: {', '.join(slots)}")
        for slot in slots:
            entry = mapping.get(slot)
            if entry is not None:
                errors.extend(_validate_inline_mapping_entry(f"{name}.{slot}", entry))
        return errors

    if action in BUILT_IN_ACTIONS or action == "disabled":
        return errors

    errors.append(f"'{name}' has invalid action '{action}'")
    return errors


def _validate_keys(name: str, keys) -> list[str]:
    if not isinstance(keys, list) or not keys:
        return [f"'{name}' needs a non-empty 'keys' list"]
    errors: list[str] = []
    for key in keys:
        if not isinstance(key, str):
            errors.append(f"'{name}' keys must be strings")
        elif not _is_valid_key(key):
            errors.append(f"'{name}' has invalid key name: '{key}'")
    return errors


def _validate_inline_mapping_entry(name: str, mapping: dict) -> list[str]:
    """Validate one slot of a gesture split -- a set of keys, or a built-in."""
    if not isinstance(mapping, dict):
        return [f"'{name}' must be a dict, got {type(mapping).__name__}"]
    if "repeat" in mapping:
        return [f"'{name}' sets 'repeat'; only a passthrough key repeats, at the system rate"]

    if "keys" in mapping:
        return _validate_keys(name, mapping["keys"])

    action = mapping.get("action")
    if action in BUILT_IN_ACTIONS or action == "disabled":
        return []
    return [f"'{name}' must set 'keys', or name a built-in action"]


def _is_valid_key(key_name: str) -> bool:
    """Check if a key name is recognized by the keyboard backend."""
    try:
        from .keyboard_output import is_valid_key
        return is_valid_key(key_name)
    except ModuleNotFoundError as e:
        if e.name not in ("pynput", "keyboard", "Quartz"):
            raise
        return _is_valid_key_static(key_name)


def _is_valid_key_static(key_name: str) -> bool:
    """Fallback key validation when keyboard backend deps are unavailable."""
    lower = key_name.lower().strip()
    if len(lower) == 1:
        return True
    return lower in {
        "ctrl", "control", "ctrl_l", "ctrl_r",
        "alt", "alt_l", "alt_r", "option",
        "shift", "shift_l", "shift_r",
        "cmd", "command", "cmd_l", "cmd_r",
        "windows", "win", "super",
        "enter", "return", "tab", "space", "backspace",
        "delete", "escape", "esc",
        "up", "down", "left", "right",
        "home", "end", "page_up", "page_down", "caps_lock",
        "print_screen", "insert", "menu", "num_lock", "pause", "scroll_lock",
        "fn", "function",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
        "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    }


# How many previous versions of a config to keep. Every save writes one, so
# without a cap an actively edited config quietly accumulates thousands.
BACKUP_HISTORY = 20


def _prune_backups(backup_dir: Path, stem: str, suffix: str) -> None:
    backups = sorted(backup_dir.glob(f"{stem}-*{suffix}"))
    for stale in backups[:-BACKUP_HISTORY]:
        try:
            stale.unlink()
        except OSError:
            logger.debug("Could not remove old config backup: %s", stale)


def save_config(config: dict, path: str | None = None) -> Path:
    """Save configuration dict to a JSON file.

    Args:
        config: The complete configuration dict to save.
        path: Target file path. Defaults to USER_CONFIG_PATH.
    """
    errors = validate_config(config)
    if errors:
        error_msg = "Invalid configuration:\n" + "\n".join(f"  - {e}" for e in errors)
        raise ValueError(error_msg)

    target = Path(path) if path else Path(USER_CONFIG_PATH)
    target.parent.mkdir(parents=True, exist_ok=True)

    if target.exists():
        backup_dir = target.parent / "backups"
        backup_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup_path = backup_dir / f"{target.stem}-{timestamp}{target.suffix}"
        shutil.copy2(target, backup_path)
        _prune_backups(backup_dir, target.stem, target.suffix)

    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            prefix=f".{target.name}.",
            suffix=".tmp",
            delete=False,
        ) as file:
            temp_path = Path(file.name)
            json.dump(config, file, ensure_ascii=False, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp_path, target)
        try:
            directory_fd = os.open(target.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            # Some filesystems do not support syncing directory descriptors.
            pass
    except Exception:
        if temp_path is not None:
            try:
                temp_path.unlink(missing_ok=True)
            except OSError:
                pass
        raise

    logger.info("Config saved to: %s", target)
    return target
