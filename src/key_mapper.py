"""Button/axis event to keyboard action translation engine.

Translates Joy-Con button presses and stick directions into keyboard actions
based on the loaded configuration. config_loader owns the list of action types
this dispatches (BUILT_IN_ACTIONS + GESTURE_SLOTS + "passthrough"); the shapes
are:

- passthrough: the button *is* the key. Modifiers stay down while it is held
  and the rest re-taps on the system repeat schedule.
- short_long / double_tap / multi_trigger: one press split into named slots,
  each holding one discrete action.
- the built-ins, whose levels are part of the action itself.

Every duration-based split -- the three gestures above and the built-ins --
uses the same threshold, so "长按" means one thing across the whole product.
It comes from config/user.json's `long_press_threshold`, falling back to
constants.DEFAULT_LONG_PRESS_THRESHOLD; a single button may still override it
with its own `threshold`.
"""

from __future__ import annotations

import time
import logging
import importlib
import subprocess
import sys
import threading

from . import key_repeat, keyboard_output
from .config_loader import get_profile
from .constants import (
    DEFAULT_DOUBLE_TAP_TIMEOUT,
    DEFAULT_LONG_PRESS_THRESHOLD,
    get_button_indices,
    get_button_names,
)
from .window_switcher import (
    WindowCycler,
    get_foreground_process_name,
    find_windows,
)

logger = logging.getLogger(__name__)

# How long to let a just-pressed modifier register before sending the key it
# modifies. Matches the gap the combination path uses between its key-downs.
_MODIFIER_SETTLE = 0.012



class KeyMapper:
    """Maps controller events to keyboard actions using a configuration dict."""

    def __init__(self, config: dict, mode: str = "single_right") -> None:
        """Initialize with a validated config dict and connection mode.

        `mode` selects which of config["profiles"] this instance reads its
        mappings from (get_profile handles the lookup) -- each side (left,
        right) gets its own independent KeyMapper instance, each locked to
        its own profile ("single_left"/"single_right") for the life of the
        process, so a left-hand mapping is never affected by whether the
        right controller happens to be connected too, or vice versa.
        """
        self._mode = mode
        self._button_indices = get_button_indices(mode)
        self._button_names = get_button_names(mode)

        mappings = get_profile(config, mode).get("mappings", {})
        long_threshold = config.get("long_press_threshold", DEFAULT_LONG_PRESS_THRESHOLD)
        self._double_tap_timeout = config.get("double_tap_timeout", DEFAULT_DOUBLE_TAP_TIMEOUT)

        # Build button index/name → mapping dict
        self._button_name_mappings: dict[str, dict] = {}
        self._button_mappings: dict[int, dict] = {}
        for btn_name, mapping in mappings.get("buttons", {}).items():
            self._button_name_mappings[btn_name] = mapping
            if btn_name in self._button_indices:
                self._button_mappings[self._button_indices[btn_name]] = mapping

        # Build direction → mapping dict
        self._direction_mappings: dict[str, dict] = {}
        for direction, mapping in mappings.get("stick_directions", {}).items():
            self._direction_mappings[direction] = mapping

        # Buttons and stick directions currently held in passthrough mode:
        #   token → {mods, taps, repeat_at, btn_name}
        # `mods` stay pressed for as long as the button is held; `taps` are
        # re-tapped on the repeat schedule. The token is a button index, or
        # ("stick", direction) for a stick held off-centre.
        self._passthrough: dict[object, dict] = {}
        # Set by whichever reader owns this mapper. Haptics are deliberately
        # rare: a buzz should tell you something you cannot otherwise know.
        # Holding a button is the one moment with no feedback at all -- you
        # cannot see when the long press "took" -- so that is where it earns
        # its place. Buzzing on every tap would be a keyboard that vibrates
        # on every key.
        self._haptic = None
        self._repeat_delay, self._repeat_interval = key_repeat.system_key_repeat()

        # Track screenshot press timing: btn_idx → (mapping, press_time)
        self._screenshot_pending: dict[object, tuple[dict, float]] = {}
        self._screenshot_lock = threading.Lock()
        self._screenshot_active = False

        # Track delayed single/double tap state: btn_idx → {mapping, time}
        self._double_tap_pending: dict[object, dict] = {}

        # Track short/long split state: btn_idx/name → {mapping, press_time, btn_name, long_done}
        self._short_long_pending: dict[object, dict] = {}

        # Track unified tap/double/hold trigger state.
        self._multi_trigger_pending: dict[object, dict] = {}
        self._multi_trigger_ignore_up: set[object] = set()

        # Dual mode runs two RawJoyConReader threads (one per Joy-Con)
        # concurrently against this same KeyMapper instance -- every public
        # entry point they (or the IPC bridge thread, for pause/reload) call
        # takes this lock so the pending-state dicts below are never read
        # and mutated by two threads at once. Reentrant so a locked method
        # calling another locked method on the same thread doesn't deadlock.
        self._state_lock = threading.RLock()

        self._long_threshold = long_threshold

        # Stick mapping enabled (controllable from GUI)
        self._stick_enabled: bool = True
        self._paused: bool = False
        # While set, only these buttons do anything. The onboarding key steps
        # need the one key they are teaching to really work -- X really
        # focusing the field, B really deleting -- while a stray Y (⌘Tab)
        # would take the user out of the window mid-lesson.
        self._allowed_buttons: frozenset[str] | None = None

        # Window cycler for VS Code window switching
        self._window_cycler = WindowCycler()

        # Window switch overlay and state (tkinter root set later via set_tk_root)
        self._switcher_overlay = None
        self._ws_held: bool = False
        self._ws_button_index: int = -1  # tracks which button triggered window_switch
        self._ws_press_time: float = 0.0
        self._ws_overlay_active: bool = False
        self._ws_last_move: float = 0.0
        self._ws_move_interval: float = config.get("switch_scroll_interval", 400) / 1000.0

        # Persistent Joy-Con window picker. Opened by SL/SR raw HID buttons.
        self._picker_active: bool = False

        # Locked macOS app switcher. Y short press is Cmd+Tab; Y long press
        # keeps Cmd held so the stick can navigate before confirmation.
        self._app_switch_pending: dict[object, dict] = {}
        self._app_switch_active = False
        self._app_switch_cmd_held = False
        self._app_switch_last_input = 0.0
        self._app_switch_timeout = config.get("app_switch_mode_timeout", 3.0)

        logger.info(
            "KeyMapper initialized: %d button mappings, %d direction mappings, "
            "long_press_threshold=%.2fs, double_tap_timeout=%.2fs",
            len(self._button_mappings),
            len(self._direction_mappings),
            self._long_threshold,
            self._double_tap_timeout,
        )

    def _on_overlay_select(self, window_info: "WindowInfo") -> None:
        """Callback when overlay selection is confirmed."""
        from .window_switcher import switch_to_window
        switch_to_window(window_info)

    def _confirm_picker(self) -> None:
        if not self._picker_active or not self._switcher_overlay:
            return
        selected = self._switcher_overlay.selected
        self._switcher_overlay.hide()
        self._picker_active = False
        if selected:
            logger.info("window_picker selected: %s", selected.title)
            self._on_overlay_select(selected)

    def _cancel_picker(self) -> None:
        if not self._picker_active or not self._switcher_overlay:
            return
        self._switcher_overlay.hide()
        self._picker_active = False
        logger.info("window_picker cancelled")

    def _open_window_picker(self, scope: str, btn_name: str) -> None:
        if self._switcher_overlay is None:
            logger.warning("window_picker [%s] skipped: overlay is not ready", btn_name)
            return

        all_windows = find_windows(None)
        if scope == "app":
            foreground = get_foreground_process_name()
            windows = [w for w in all_windows if w.app_name.lower() == foreground]
            title = "当前 App 窗口"
        else:
            windows = all_windows
            title = "所有窗口"

        if not windows:
            logger.warning("window_picker [%s] found no windows (scope=%s)", btn_name, scope)
            return

        initial = self._find_current_window_index(windows)
        self._switcher_overlay.show(windows, initial_index=initial, title=title)
        self._picker_active = True
        logger.info("window_picker [%s] opened: %d windows (scope=%s)", btn_name, len(windows), scope)

    def set_tk_root(self, root: "tk.Tk") -> None:
        """Set the tkinter root for overlay creation. Call from main thread."""
        import tkinter as tk
        SwitcherOverlay = importlib.import_module("src.switcher_overlay").SwitcherOverlay

        if isinstance(root, tk.Tk) and self._switcher_overlay is None:
            self._switcher_overlay = SwitcherOverlay(root, on_select=self._on_overlay_select)

    def _find_current_window_index(self, windows: list["WindowInfo"]) -> int:
        """Find the index of the current foreground window in the list."""
        fg_name = get_foreground_process_name()
        for i, w in enumerate(windows):
            if w.app_name.lower() == fg_name:
                return i
        return 0

    def button_down(self, button_index: int) -> None:
        """Handle a button press event."""
        if self._paused:
            return
        mapping = self._button_mappings.get(button_index)
        if mapping is None:
            return

        btn_name = _button_label(button_index, self._mode)
        self._button_down_mapped(button_index, btn_name, mapping)

    def button_down_name(self, btn_name: str) -> None:
        """Handle a named button press from non-pygame input sources."""
        if self._paused or not self._button_allowed(btn_name):
            return
        mapping = self._button_name_mappings.get(btn_name)
        if mapping is None:
            logger.debug("button [%s] ignored: no mapping for mode %s", btn_name, self._mode)
            return
        self._button_down_mapped(("raw", btn_name), btn_name, mapping)

    def _button_down_mapped(self, button_index, btn_name: str, mapping: dict) -> None:
        with self._state_lock:
            self._button_down_mapped_locked(button_index, btn_name, mapping)

    def _button_down_mapped_locked(self, button_index, btn_name: str, mapping: dict) -> None:
        if self._app_switch_active and mapping.get("action") != "app_switch_mode":
            if btn_name == "A":
                self._exit_app_switch_mode(confirm=True)
            elif btn_name in ("SR", "B", "X"):
                self._exit_app_switch_mode(confirm=False)
            return

        if self._picker_active:
            if btn_name == "A":
                self._confirm_picker()
            elif btn_name in ("B", "X"):
                self._cancel_picker()
            return

        action = mapping["action"]
        logger.debug("button [%s] action: %s", btn_name, action)
        if action == "disabled":
            logger.debug("disabled [%s]", btn_name)
            return

        if action == "passthrough":
            self._begin_passthrough(button_index, btn_name, mapping.get("keys", []))

        elif action == "focus_input":
            keyboard_output.focus_input()
            logger.debug("focus_input [%s]", btn_name)

        elif action == "window_switch":
            # Record press time and button index, decide short vs long in poll/button_up
            self._ws_held = True
            self._ws_button_index = button_index
            self._ws_press_time = time.monotonic()
            self._ws_overlay_active = False
            logger.debug("window_switch DOWN [%s] (waiting)", btn_name)

        elif action == "app_switch_mode":
            self._app_switch_pending[button_index] = {
                "press_time": time.monotonic(),
                "btn_name": btn_name,
            }
            logger.debug("app_switch_mode DOWN [%s] (waiting)", btn_name)

        elif action == "double_tap":
            self._handle_double_tap_down(button_index, btn_name, mapping)

        elif action == "short_long":
            self._short_long_pending[button_index] = {
                "mapping": mapping,
                "press_time": time.monotonic(),
                "btn_name": btn_name,
                "long_done": False,
            }
            logger.debug("short_long DOWN [%s] (waiting)", btn_name)

        elif action == "multi_trigger":
            self._handle_multi_trigger_down(button_index, btn_name, mapping)

        elif action == "screenshot":
            self._screenshot_pending[button_index] = (mapping, time.monotonic())
            logger.debug("screenshot DOWN [%s]", btn_name)

        elif action == "window_picker":
            self._open_window_picker(mapping.get("scope", "all"), btn_name)

        elif action == "macro":
            self._execute_macro(mapping, btn_name)

        elif action == "exec":
            self._execute_exec(mapping, btn_name)

    def button_up(self, button_index: int) -> None:
        """Handle a button release event."""
        if self._paused:
            return
        btn_name = _button_label(button_index, self._mode)
        self._button_up_mapped(button_index, btn_name)

    def button_up_name(self, btn_name: str) -> None:
        """Handle a named button release from non-pygame input sources."""
        if self._paused or not self._button_allowed(btn_name):
            return
        self._button_up_mapped(("raw", btn_name), btn_name)

    def _button_up_mapped(self, button_index, btn_name: str) -> None:
        with self._state_lock:
            self._button_up_mapped_locked(button_index, btn_name)

    def _button_up_mapped_locked(self, button_index, btn_name: str) -> None:
        if button_index in self._multi_trigger_ignore_up:
            self._multi_trigger_ignore_up.discard(button_index)
            return

        if button_index in self._app_switch_pending:
            info = self._app_switch_pending.pop(button_index)
            elapsed = time.monotonic() - info["press_time"]
            if elapsed < self._long_threshold:
                keyboard_output.send_combination(["cmd", "tab"])
                logger.debug("app_switch_mode UP [%s] → quick cmd+tab", btn_name)
            return

        if button_index in self._screenshot_pending:
            mapping, press_time = self._screenshot_pending.pop(button_index)
            paste = time.monotonic() - press_time < self._long_threshold
            self._run_screenshot(paste=paste)
            logger.debug("screenshot UP [%s] → paste=%s", btn_name, paste)
            return

        if button_index in self._short_long_pending:
            info = self._short_long_pending.pop(button_index)
            # Nothing to do when the long action already fired -- the short
            # action is only what a *release before the threshold* means.
            if not info["long_done"]:
                self._execute_inline_action(info["mapping"]["short"], btn_name)
                logger.debug("short_long UP [%s] → short", btn_name)
            return

        if button_index in self._multi_trigger_pending:
            info = self._multi_trigger_pending[button_index]
            if info["long_done"]:
                del self._multi_trigger_pending[button_index]
                return

            info["released"] = True
            info["release_time"] = time.monotonic()
            if info["mapping"].get("double") is None:
                tap_mapping = info["mapping"].get("tap")
                if tap_mapping:
                    self._execute_inline_action(tap_mapping, btn_name)
                    logger.debug("multi_trigger UP [%s] → tap", btn_name)
                del self._multi_trigger_pending[button_index]
            return

        if button_index in self._passthrough:
            self._end_passthrough(button_index, btn_name)

        # Handle window_switch release — only if this is the button that started it
        if self._ws_held and button_index == self._ws_button_index:
            self._ws_held = False
            self._ws_button_index = -1

            if self._ws_overlay_active and self._switcher_overlay:
                # Long press: select the highlighted window and hide overlay
                selected = self._switcher_overlay.selected
                self._switcher_overlay.hide()
                self._ws_overlay_active = False
                if selected:
                    self._on_overlay_select(selected)
                    logger.info("window_switch UP [%s] → selected: %s", btn_name, selected.title)
            else:
                # Short press: immediate switch to next
                target = self._window_cycler.next()
                if target:
                    logger.info("window_switch UP [%s] → quick: %s", btn_name, target.title)
                else:
                    logger.warning("window_switch UP [%s] → no windows found", btn_name)

    def poll(self) -> None:
        """Call every polling cycle to handle auto-action long press activation.

        Checks if any pending auto-action (button or stick) has exceeded
        the long press threshold, and if so, activates the hold.
        """
        with self._state_lock:
            self._poll_locked()

    def _poll_locked(self) -> None:
        if self._paused:
            return

        now = time.monotonic()

        # A held passthrough key repeats exactly like a held keyboard key:
        # macOS does not auto-repeat synthetic key events, so the repeats are
        # produced here -- on the user's own system repeat schedule, so the
        # button feels like the key it stands for. Modifier-only mappings
        # have no `taps` and so never repeat, which is also what a keyboard
        # does with a held ⌥.
        for info in self._passthrough.values():
            repeat_at = info["repeat_at"]
            if repeat_at is None or now < repeat_at:
                continue
            for key in info["taps"]:
                keyboard_output.tap(key)
            info["repeat_at"] = now + self._repeat_interval

        for btn_idx in list(self._app_switch_pending.keys()):
            info = self._app_switch_pending[btn_idx]
            if now - info["press_time"] >= self._long_threshold:
                del self._app_switch_pending[btn_idx]
                self._buzz()
                self._enter_app_switch_mode(info["btn_name"])

        if self._app_switch_active:
            if now - self._app_switch_last_input >= self._app_switch_timeout:
                self._exit_app_switch_mode(confirm=True)

        # Delayed single taps waiting to see if a second tap arrives.
        for btn_idx in list(self._double_tap_pending.keys()):
            info = self._double_tap_pending[btn_idx]
            timeout = info["mapping"].get("timeout", self._double_tap_timeout)
            if now - info["time"] >= timeout:
                self._execute_inline_action(info["mapping"]["single"], info["btn_name"])
                del self._double_tap_pending[btn_idx]

        for btn_idx in list(self._short_long_pending.keys()):
            info = self._short_long_pending[btn_idx]
            threshold = info["mapping"].get("threshold", self._long_threshold)
            if not info["long_done"] and now - info["press_time"] >= threshold:
                self._execute_inline_action(info["mapping"]["long"], info["btn_name"])
                info["long_done"] = True
                self._buzz()
                logger.debug("short_long [%s] → long", info["btn_name"])

        for btn_idx in list(self._multi_trigger_pending.keys()):
            info = self._multi_trigger_pending[btn_idx]
            mapping = info["mapping"]
            threshold = mapping.get("threshold", self._long_threshold)
            if (
                mapping.get("hold") is not None
                and not info["released"]
                and not info["long_done"]
                and now - info["press_time"] >= threshold
            ):
                self._execute_inline_action(mapping["hold"], info["btn_name"])
                info["long_done"] = True
                self._buzz()
                logger.debug("multi_trigger [%s] → hold", info["btn_name"])
                continue

            timeout = mapping.get("timeout", self._double_tap_timeout)
            if info["released"] and now - info["release_time"] >= timeout:
                tap_mapping = mapping.get("tap")
                if tap_mapping:
                    self._execute_inline_action(tap_mapping, info["btn_name"])
                    logger.debug("multi_trigger [%s] → delayed tap", info["btn_name"])
                del self._multi_trigger_pending[btn_idx]

        # Stick auto-actions: already activated immediately in stick_direction(), no pending check needed

        # Sequence repeat (e.g., Alt held + Tab every N ms)
        # Window switch: long press → show overlay; stick_direction selects.
        if self._ws_held and not self._ws_overlay_active and self._switcher_overlay:
            if now - self._ws_press_time >= self._long_threshold:
                windows = find_windows(self._window_cycler.app_names)
                if windows:
                    initial = self._find_current_window_index(windows)
                    self._switcher_overlay.show(windows, initial_index=initial)
                    self._ws_overlay_active = True
                    self._buzz()
                    self._ws_last_move = now
                    logger.info("window_switch overlay: %d windows", len(windows))

    def _release_stick_auto(self) -> None:
        """Let go of whichever direction the stick was holding."""
        for token in [k for k in self._passthrough if isinstance(k, tuple) and k[0] == "stick"]:
            self._end_passthrough(token, token[1])

    def stick_direction(self, direction: str) -> None:
        """Handle a stick direction change event."""
        with self._state_lock:
            self._stick_direction_locked(direction)

    def _stick_direction_locked(self, direction: str) -> None:
        if self._paused or self._allowed_buttons is not None:
            return

        if self._app_switch_active:
            if direction in ("right", "down-right", "up-right"):
                self._app_switch_step(reverse=False)
            elif direction in ("left", "down-left", "up-left"):
                self._app_switch_step(reverse=True)
            elif direction in ("up", "down"):
                logger.debug("app_switch_mode stick %s ignored", direction)
            return

        if self._picker_active and self._switcher_overlay:
            if direction in ("down", "right", "down-right", "up-right"):
                selected = self._switcher_overlay.move_next()
                if selected:
                    logger.debug("window_picker move next → %s", selected.title)
            elif direction in ("up", "left", "up-left", "down-left"):
                selected = self._switcher_overlay.move_previous()
                if selected:
                    logger.debug("window_picker move previous → %s", selected.title)
            return

        if self._ws_held and self._ws_overlay_active and self._switcher_overlay:
            if direction in ("down", "right", "down-right", "up-right"):
                selected = self._switcher_overlay.move_next()
                if selected:
                    logger.debug("window_switch overlay move next → %s", selected.title)
            elif direction in ("up", "left", "up-left", "down-left"):
                selected = self._switcher_overlay.move_previous()
                if selected:
                    logger.debug("window_switch overlay move previous → %s", selected.title)
            return

        if not self._stick_enabled:
            return

        # Release any previously active stick direction hold
        self._release_stick_auto()

        mapping = self._direction_mappings.get(direction)
        if mapping is None:
            return

        if mapping.get("action") != "passthrough":
            logger.warning("stick [%s] has unsupported action %r", direction, mapping.get("action"))
            return
        self._begin_passthrough(("stick", direction), direction, mapping.get("keys", []))

    def stick_centered(self) -> None:
        """Handle stick returning to center."""
        with self._state_lock:
            if self._paused or self._allowed_buttons is not None:
                return
            if not self._stick_enabled:
                return
            self._release_stick_auto()
            logger.debug("stick centered")

    def set_paused(self, paused: bool) -> None:
        """Pause or resume all mapping output.

        Pausing releases every held key and cancels pending actions before
        future input is ignored. Resuming only re-enables future input; it does
        not replay any button state that occurred while paused.
        """
        with self._state_lock:
            if self._paused == paused:
                return
            self._paused = paused
            if paused:
                self.release_all()
                from . import keyboard_output
                keyboard_output.release_all()
            logger.info("Key mapping %s", "paused" if paused else "resumed")

    def set_allowed_buttons(self, buttons) -> None:
        """Let only `buttons` through, or everything again with None.

        Narrowing releases whatever is held first, the same as pausing does:
        a key held down across the switch would otherwise never see its
        release.
        """
        allowed = frozenset(buttons) if buttons is not None else None
        with self._state_lock:
            if allowed == self._allowed_buttons:
                return
            self._allowed_buttons = allowed
            self.release_all()
            from . import keyboard_output
            keyboard_output.release_all()

    def _button_allowed(self, btn_name: str) -> bool:
        return self._allowed_buttons is None or btn_name in self._allowed_buttons

    @property
    def output_held(self) -> bool:
        """Output is suspended in whole or in part, for whatever reason."""
        return self._paused or self._allowed_buttons is not None

    def set_haptic(self, callback) -> None:
        self._haptic = callback

    def _buzz(self) -> None:
        if self._haptic is None:
            return
        try:
            self._haptic()
        except Exception:
            logger.debug("haptic failed", exc_info=True)

    @property
    def paused(self) -> bool:
        return self._paused

    def switch_profile(self, config: dict, mode: str) -> None:
        """Switch to a different button mapping profile at runtime.

        Releases all held keys first, then rebuilds mappings from the
        profile for the given connection mode.
        """
        with self._state_lock:
            self.release_all()
            self._mode = mode
            self._double_tap_timeout = config.get("double_tap_timeout", DEFAULT_DOUBLE_TAP_TIMEOUT)
            # Re-read in case the user changed their keyboard repeat rate in
            # System Settings since this process started.
            self._repeat_delay, self._repeat_interval = key_repeat.system_key_repeat()
            self._button_indices = get_button_indices(mode)
            self._button_names = get_button_names(mode)

            mappings = get_profile(config, mode).get("mappings", {})

            self._button_name_mappings.clear()
            self._button_mappings.clear()
            for btn_name, mapping in mappings.get("buttons", {}).items():
                self._button_name_mappings[btn_name] = mapping
                if btn_name in self._button_indices:
                    self._button_mappings[self._button_indices[btn_name]] = mapping

            self._direction_mappings.clear()
            for direction, mapping in mappings.get("stick_directions", {}).items():
                self._direction_mappings[direction] = mapping

            logger.info(
                "Switched to profile '%s': %d button mappings, %d direction mappings",
                mode, len(self._button_mappings), len(self._direction_mappings),
            )

    def release_all(self) -> None:
        """Release all currently held keys and cancel pending auto actions."""
        with self._state_lock:
            self._release_all_locked()

    def _release_all_locked(self) -> None:
        # Hide overlay if active
        self._ws_held = False
        self._ws_button_index = -1
        self._ws_overlay_active = False
        self._picker_active = False
        if self._switcher_overlay:
            self._switcher_overlay.hide()
        self._exit_app_switch_mode(confirm=False)
        # Release sequences in reverse
        for token in list(self._passthrough):
            self._end_passthrough(token, str(token))


        # Release holds



    def _execute_macro(self, mapping: dict, btn_name: str) -> None:
        """Execute a macro: a sequence of steps, optionally filtered by foreground window.

        Config format:
            {
                "action": "macro",
                "if_window": "code.exe",   # optional: only run if this process is foreground
                "steps": [
                    {"type": "combination", "keys": ["ctrl", "shift", "p"]},
                    {"type": "delay", "ms": 300},
                    {"type": "type", "text": "some text"},
                    {"type": "tap", "key": "enter"},
                ]
            }
        """
        # Check window filter
        if_window = mapping.get("if_window")
        if if_window:
            fg = get_foreground_process_name()
            if fg != if_window:
                logger.debug("macro [%s] skipped: foreground is '%s', need '%s'",
                             btn_name, fg, if_window)
                return

        steps = mapping.get("steps", [])
        logger.info("macro [%s] executing %d steps", btn_name, len(steps))

        for i, step in enumerate(steps):
            step_type = step.get("type")

            if step_type == "combination":
                keyboard_output.send_combination(step["keys"])

            elif step_type == "tap":
                keyboard_output.tap(step["key"])

            elif step_type == "hold":
                keyboard_output.press(step["key"])

            elif step_type == "release":
                keyboard_output.release(step["key"])

            elif step_type == "type":
                keyboard_output.type_text(step["text"])

            elif step_type == "delay":
                time.sleep(step.get("ms", 100) / 1000.0)

            else:
                logger.warning("macro [%s] unknown step type '%s' at step %d",
                               btn_name, step_type, i)

    def _execute_exec(self, mapping: dict, btn_name: str) -> None:
        """Run a shell command. Non-blocking via Popen.

        Config format:
            {"action": "exec", "command": "open -a 'Mission Control'"}
            # or list form (no shell parsing):
            {"action": "exec", "command": ["open", "-a", "Mission Control"]}
        """
        import subprocess
        cmd = mapping.get("command")
        if not cmd:
            logger.warning("exec [%s] missing 'command' field", btn_name)
            return
        try:
            if isinstance(cmd, str):
                subprocess.Popen(cmd, shell=True)
            else:
                subprocess.Popen(list(cmd))
            logger.debug("exec [%s] → %s", btn_name, cmd)
        except Exception:
            logger.exception("exec [%s] failed: %s", btn_name, cmd)

    def _handle_double_tap_down(self, button_index, btn_name: str, mapping: dict) -> None:
        pending = self._double_tap_pending.pop(button_index, None)
        if pending is not None:
            self._execute_inline_action(mapping["double"], btn_name)
            logger.debug("double_tap [%s] → double", btn_name)
            return
        self._double_tap_pending[button_index] = {
            "mapping": mapping,
            "time": time.monotonic(),
            "btn_name": btn_name,
        }
        logger.debug("double_tap [%s] waiting", btn_name)

    def _handle_multi_trigger_down(self, button_index, btn_name: str, mapping: dict) -> None:
        pending = self._multi_trigger_pending.pop(button_index, None)
        if pending is not None and pending.get("released") and mapping.get("double") is not None:
            self._execute_inline_action(mapping["double"], btn_name)
            self._multi_trigger_ignore_up.add(button_index)
            logger.debug("multi_trigger [%s] → double", btn_name)
            return

        self._multi_trigger_pending[button_index] = {
            "mapping": mapping,
            "press_time": time.monotonic(),
            "release_time": 0.0,
            "btn_name": btn_name,
            "released": False,
            "long_done": False,
        }
        logger.debug("multi_trigger DOWN [%s] (waiting)", btn_name)

    def _begin_passthrough(self, token, btn_name: str, keys: list[str]) -> None:
        """Hold a button down the way the keyboard key it stands for behaves.

        Modifiers are pressed and stay pressed until release; the remaining
        key is tapped once now and then re-tapped on the system repeat
        schedule, which is how a keyboard behaves when you hold ⌘V or ⌫.
        """
        if not keys:
            return
        if token in self._passthrough:
            self._end_passthrough(token, btn_name)

        mods = [k for k in keys if key_repeat.is_modifier(k)]
        taps = [k for k in keys if not key_repeat.is_modifier(k)]

        for key in mods:
            keyboard_output.press(key)
        if mods and taps:
            # The OS does not report a modifier as active on the very next
            # event just because its key-down was posted: the ambient state
            # that carries it through needs a moment to settle. Without this
            # ⌘Space arrives as a bare space -- the same settle the proven
            # "combination" path already does between its key-downs.
            time.sleep(_MODIFIER_SETTLE)
        for key in taps:
            keyboard_output.tap(key)

        self._passthrough[token] = {
            "mods": mods,
            "taps": taps,
            # Modifier-only mappings simply stay down, so they never repeat.
            "repeat_at": (time.monotonic() + self._repeat_delay) if taps else None,
            "btn_name": btn_name,
        }
        logger.debug("passthrough DOWN [%s] → %s", btn_name, "+".join(keys))

    def _end_passthrough(self, token, btn_name: str) -> None:
        info = self._passthrough.pop(token, None)
        if info is None:
            return
        for key in reversed(info["mods"]):
            keyboard_output.release(key)
        logger.debug("passthrough UP [%s]", btn_name)

    def _execute_inline_action(self, mapping: dict, btn_name: str) -> None:
        # A gesture slot is one discrete action -- "what this button does
        # when you tap it" or "...when you hold it" -- so the common case is
        # simply a set of keys sent once. Built-ins still name an action.
        keys = mapping.get("keys")
        if keys:
            keyboard_output.send_combination(list(keys))
            logger.debug("inline [%s] → %s", btn_name, "+".join(keys))
            return

        action = mapping.get("action")
        if action == "focus_input":
            keyboard_output.focus_input()
            return
        if action == "window_switch":
            target = self._window_cycler.next()
            if target:
                logger.info("inline window_switch [%s] → %s", btn_name, target.title)
        elif action == "app_switch_mode":
            keys = ["cmd", "tab"] if sys.platform == "darwin" else ["alt", "tab"]
            keyboard_output.send_combination(keys)
        elif action == "screenshot":
            self._run_screenshot(paste=mapping.get("paste", True))
        elif action == "exec":
            self._execute_exec(mapping, btn_name)
        elif action == "macro":
            self._execute_macro(mapping, btn_name)
        elif action in (None, "disabled"):
            return
        else:
            logger.warning("inline action [%s] unsupported: %s", btn_name, action)

    def _enter_app_switch_mode(self, btn_name: str) -> None:
        if self._app_switch_active:
            return
        keyboard_output.press("cmd")
        self._app_switch_cmd_held = True
        time.sleep(0.02)
        keyboard_output.tap("tab")
        self._app_switch_active = True
        self._app_switch_last_input = time.monotonic()
        logger.info("app_switch_mode entered [%s] → cmd held, second app highlighted", btn_name)

    def _exit_app_switch_mode(self, confirm: bool) -> None:
        if not self._app_switch_active:
            return
        if not confirm and self._app_switch_cmd_held:
            keyboard_output.tap("escape")
            time.sleep(0.02)
        if self._app_switch_cmd_held:
            keyboard_output.release("cmd")
        self._app_switch_active = False
        self._app_switch_cmd_held = False
        self._app_switch_last_input = 0.0
        logger.info("app_switch_mode exited (confirm=%s)", confirm)

    def _app_switch_step(self, reverse: bool) -> None:
        if not self._app_switch_cmd_held:
            keyboard_output.press("cmd")
            self._app_switch_cmd_held = True
        self._app_switch_last_input = time.monotonic()
        if reverse:
            keyboard_output.press("shift")
            keyboard_output.tap("tab")
            keyboard_output.release("shift")
            logger.debug("app_switch_mode previous → cmd+shift+tab")
        else:
            keyboard_output.tap("tab")
            logger.debug("app_switch_mode next → cmd+tab")

    def _run_screenshot(self, paste: bool) -> None:
        with self._screenshot_lock:
            if self._screenshot_active:
                logger.info("screenshot already active; duplicate trigger ignored")
                return
            self._screenshot_active = True
        thread = threading.Thread(target=self._screenshot_worker, args=(paste,), daemon=True)
        thread.start()

    def _screenshot_worker(self, paste: bool) -> None:
        try:
            if sys.platform == "darwin":
                self._macos_screenshot_worker(paste)
            else:
                self._screencapture_worker(paste)
        finally:
            with self._screenshot_lock:
                self._screenshot_active = False

    def _macos_screenshot_worker(self, paste: bool) -> None:
        front_app = _frontmost_macos_app() if paste else None
        try:
            result = subprocess.run(["screencapture", "-cx"], timeout=10)
        except Exception:
            logger.exception("fullscreen screenshot failed")
            return

        if result.returncode != 0:
            logger.info("fullscreen screenshot cancelled or failed: %s", result.returncode)
            return

        logger.info("fullscreen screenshot captured to clipboard (paste=%s)", paste)
        if paste:
            _activate_macos_app(front_app)
            time.sleep(0.2)
            keyboard_output.send_combination(["cmd", "v"])
            logger.info("fullscreen screenshot pasted")

    def _screencapture_worker(self, paste: bool) -> None:
        front_app = _frontmost_macos_app() if paste else None
        try:
            result = subprocess.run(["screencapture", "-cx"], timeout=10)
        except Exception:
            logger.exception("screenshot failed")
            return

        if result.returncode != 0:
            logger.info("screenshot cancelled or failed: %s", result.returncode)
            return

        if paste:
            _activate_macos_app(front_app)
            time.sleep(0.2)
            keyboard_output.send_combination(["cmd", "v"])


def _button_label(button_index: int, mode: str = "single_right") -> str:
    """Get human-readable name for a button index."""
    return get_button_names(mode).get(button_index, f"BTN_{button_index}")


def _frontmost_macos_app():
    if sys.platform != "darwin":
        return None
    try:
        from AppKit import NSWorkspace
        return NSWorkspace.sharedWorkspace().frontmostApplication()
    except Exception:
        logger.debug("Unable to capture frontmost macOS app", exc_info=True)
        return None


def _activate_macos_app(app) -> None:
    if sys.platform != "darwin" or app is None:
        return
    try:
        app.activateWithOptions_(1 << 1)
    except Exception:
        logger.debug("Unable to reactivate macOS app after screenshot", exc_info=True)
