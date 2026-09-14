"""Keyboard simulation wrapper — macOS native-client only.

All real key synthesis happens on the Swift side (InputGateway.swift,
CoreGraphicsKeyboardEmitter), reached over the local Unix socket set up by
NativeInputClient. Every current entry point that actually sends keys sets
JOYHARNESS_INPUT_BACKEND=native / JOYHARNESS_NATIVE_INPUT_SOCKET before
starting (RuntimeManager.swift's bundled executable in production, or
scripts/start-joyharness.sh for a Preview build's manual "启动服务").

is_valid_key() is a pure string check used by config_loader's validation
and deliberately does not require the native client to be configured --
callers like `--list-controls` only need to validate config shape, not
actually send input. Everything that DOES send input goes through
_native_client() below, which raises clearly (once, when actually needed)
rather than silently falling back to a separate, unmaintained
keyboard-synthesis implementation.

Provides press/release/tap/combination operations with state tracking
to prevent double-press and ensure cleanup.
"""

from __future__ import annotations

import logging

from .native_input_client import NativeInputClient

logger = logging.getLogger(__name__)

_held_keys: set[str] = set()
_client_cache: NativeInputClient | None = None
_client_resolved = False


def _native_client() -> NativeInputClient:
    global _client_cache, _client_resolved
    if not _client_resolved:
        _client_cache = NativeInputClient.from_environment()
        _client_resolved = True
    if _client_cache is None:
        raise RuntimeError(
            "JoyHarness runtime tried to send a key without the native input "
            "backend configured. Set JOYHARNESS_INPUT_BACKEND=native and "
            "JOYHARNESS_NATIVE_INPUT_SOCKET before starting (RuntimeManager.swift "
            "and scripts/start-joyharness.sh already do this)."
        )
    return _client_cache


def is_valid_key(key_name: str) -> bool:
    return _is_valid_key_static(key_name)


# ---------------------------------------------------------------------------
# Public API (unchanged interface)
# ---------------------------------------------------------------------------

def press(key: str) -> None:
    """Hold a key down. No-op if already held."""
    if key in _held_keys:
        return
    try:
        _native_client().request("press", key=key)
        _held_keys.add(key)
        logger.debug("keyboard press: %s", key)
    except Exception:
        logger.exception("keyboard press failed: %s", key)
        raise


def release(key: str) -> None:
    """Release a held key. No-op if not currently held."""
    if key not in _held_keys:
        return
    try:
        _native_client().request("release", key=key)
        _held_keys.discard(key)
        logger.debug("keyboard release: %s", key)
    except Exception:
        logger.exception("keyboard release failed: %s", key)
        raise


def tap(key: str, duration: float = 0.02) -> None:
    """Press and release a key immediately.

    If the key is currently held (tracked in _held_keys), temporarily
    release it, re-tap, then restore the held state.
    """
    was_held = key in _held_keys
    if was_held:
        _native_client().request("release", key=key)
        _held_keys.discard(key)

    try:
        _native_client().request("tap", key=key, duration_ms=max(1, round(duration * 1000)))
    except Exception:
        logger.exception("keyboard tap failed: %s", key)
        raise

    if was_held:
        _native_client().request("press", key=key)
        _held_keys.add(key)

    logger.debug("keyboard tap: %s", key)


def send_combination(keys: list[str], hold: float = 0.05) -> None:
    """Press multiple keys simultaneously, then release in reverse order.

    Example: send_combination(["ctrl", "c"]) -> Ctrl+C

    Keys that are currently held via press() are temporarily released,
    then restored after the combination completes.

    Args:
        keys: Key names in press order.
        hold: Duration to hold all keys before releasing (seconds).
    """
    held_in_combo = [k for k in keys if k in _held_keys]
    client = _native_client()
    for k in held_in_combo:
        client.request("release", key=k)
        _held_keys.discard(k)

    try:
        client.request("combination", keys=keys, hold_ms=max(1, round(hold * 1000)))
    except Exception:
        logger.exception("keyboard combination failed: %s", "+".join(keys))
        raise

    for k in held_in_combo:
        client.request("press", key=k)
        _held_keys.add(k)

    logger.debug("keyboard combination: %s", "+".join(keys))


def focus_input() -> None:
    """Move the caret into the frontmost window's text input.

    The native app does the work: reading and writing the accessibility tree
    needs the Accessibility grant, which only it holds.
    """
    try:
        result = _native_client().request("focus_input")
        logger.info("focus input → %s", result.get("detail", "ok"))
    except Exception as error:
        # Not every window has somewhere to type, so this must not tear the
        # reader down -- but it is logged at INFO, because a button that
        # silently does nothing is indistinguishable from a broken one.
        logger.info("focus input did nothing: %s", error)


def release_all() -> None:
    """Release every currently held key. Used for cleanup on exit or disconnect."""
    if _held_keys:
        _native_client().request("release_all")
    _held_keys.clear()


def is_held(key: str) -> bool:
    """Check if a key is currently being held."""
    return key in _held_keys


def type_text(text: str) -> None:
    """Type a string."""
    _native_client().request("type_text", text=text)
    logger.debug("typed: %s", text)


def _is_valid_key_static(key_name: str) -> bool:
    lower = key_name.lower().strip()
    if len(lower) == 1:
        return lower in set("abcdefghijklmnopqrstuvwxyz0123456789=-[]';\\,/.`")
    return lower in {
        "ctrl", "control", "ctrl_l", "ctrl_r", "alt", "alt_l", "alt_r", "option",
        "shift", "shift_l", "shift_r", "cmd", "command", "cmd_l", "cmd_r",
        "windows", "win", "super", "enter", "return", "tab", "space", "backspace",
        "delete", "escape", "esc", "up", "down", "left", "right", "home", "end",
        "page_up", "page_down", "caps_lock", "print_screen", "insert", "menu", "num_lock",
        "pause", "scroll_lock", "fn", "function",
        *(f"f{index}" for index in range(1, 21)),
    }
