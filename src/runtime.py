"""Reusable JoyHarness runtime orchestration.

macOS-only, native-client runtime: this module owns the Joy-Con mapping
service lifecycle for the headless process the native SwiftUI App spawns
(directly via RuntimeManager.swift's bundled executable in production, or
via scripts/start-joyharness.sh for a Preview build's manual "启动服务").
There is no GUI here — the native App owns all UI; this process just reads
Joy-Con input, translates it via KeyMapper, and talks back to the App over
the local status/IPC files in runtime_ipc.py.
"""

from __future__ import annotations

import logging
import signal
import threading
import time
from typing import Callable

import pygame

from .config_loader import get_platform_config_path, load_config
from .joycon_reader import find_joycon
from .keep_alive import KeepAliveManager
from .process_guard import watch_parent
from .key_mapper import KeyMapper
from .side_button_reader import RawJoyConReader

logger = logging.getLogger(__name__)


class JoyHarnessRuntime:
    """Owns the JoyHarness mapping service lifecycle."""

    def __init__(
        self,
        config: dict,
        joystick_index: int | None = None,
        pairing_instructions: Callable[[], str] | None = None,
        output: Callable[[str], None] = print,
        config_path: str | None = None,
    ) -> None:
        self.config = config
        self.joystick_index = joystick_index
        self._pairing_instructions = pairing_instructions
        self._output = output
        self.config_path = config_path

        self.stop_event: threading.Event | None = None
        # Each Joy-Con runs its own independent KeyMapper, locked to its own
        # profile (single_right / single_left) for the life of the process --
        # by product decision, a side's mappings never change based on
        # whether the other controller happens to be connected too. No
        # "dual" mode, no shared mutable profile selection.
        self.key_mapper_right: KeyMapper | None = None
        self.key_mapper_left: KeyMapper | None = None
        self.keep_alive_manager: KeepAliveManager | None = None
        self.raw_reader: RawJoyConReader | None = None
        self.raw_reader_left: RawJoyConReader | None = None
        self.ipc_bridge = None
        self._input_event_lock = threading.Lock()
        self._input_event_sequence = 0
        self._input_events: list[dict] = []
        self._started = False

    @property
    def key_mapper(self) -> KeyMapper | None:
        """Either mapper works for status/pause queries -- set_paused() and
        reload_config() always apply to both, so they're always in sync."""
        return self.key_mapper_right

    @property
    def connection_mode(self) -> str:
        """Purely descriptive (diagnostics export, status.json) -- does not
        select a profile; each side already has its own regardless."""
        left = bool(self.raw_reader_left and self.raw_reader_left.connected)
        right = bool(self.raw_reader and self.raw_reader.connected)
        if left and right:
            return "dual"
        if left:
            return "single_left"
        if right:
            return "single_right"
        return "none"

    @property
    def started(self) -> bool:
        return self._started

    def start(self) -> None:
        if self._started:
            return

        pygame.display.init()
        pygame.joystick.init()

        # pygame/SDL is only used here to log what's paired at startup; the
        # real input path (RawJoyConReader, below) reads raw HID directly.
        joystick = find_joycon(self.joystick_index)
        if joystick is None:
            self._output("No Joy-Con detected yet; macOS raw reader will wait for device.")
        else:
            self._output(f"Controller: {joystick.get_name()}")
            self._output(f"Buttons: {joystick.get_numbuttons()}, Axes: {joystick.get_numaxes()}")

        self.stop_event = threading.Event()
        # The app kills this process on a clean quit; this covers the app
        # crashing, being force quit, or the user logging out, none of which
        # run applicationWillTerminate. Without it the runtime is reparented
        # to launchd and keeps holding the controller and the IPC files.
        watch_parent(self.stop_event)
        # Always create both -- a controller that isn't plugged in yet just
        # means its reader sits waiting for the device (RawJoyConReader
        # already retries on its own), not that its mapper doesn't exist.
        self.key_mapper_right = KeyMapper(self.config, mode="single_right")
        self.key_mapper_left = KeyMapper(self.config, mode="single_left")

        selected_apps = self.config.get("selected_apps")
        if selected_apps:
            self.key_mapper_right._window_cycler.app_names = selected_apps
            self.key_mapper_left._window_cycler.app_names = selected_apps

        # Keep-alive (preventing display/system sleep) is a Windows-only
        # concern from the pre-native-client era; macOS's own idle/sleep
        # handling already respects HID activity, so this stays disabled.
        self.keep_alive_manager = KeepAliveManager(self.stop_event)
        self.keep_alive_manager.set_enabled(False)

        self.raw_reader = RawJoyConReader(
            self.stop_event,
            self.key_mapper_right,
            self.config,
            on_input=self.record_input_event,
            side="R",
        )
        self.raw_reader_left = RawJoyConReader(
            self.stop_event,
            self.key_mapper_left,
            self.config,
            on_input=self.record_input_event,
            side="L",
        )
        self.raw_reader_left.start()
        self.raw_reader.start()

        from .runtime_ipc import RuntimeIpcBridge

        self.ipc_bridge = RuntimeIpcBridge(self)
        self.ipc_bridge.start()

        from .constants import MODE_LABELS

        profile_label = MODE_LABELS.get(self.connection_mode, self.connection_mode)
        self._output(f"Connection mode: {profile_label} ({self.connection_mode})")
        self._output(f"Deadzone: {self.config['deadzone']}, Stick mode: {self.config['stick_mode']}")
        self._output("Native client runtime active.")

        self._started = True

    def run(self) -> None:
        self.start()
        try:
            self._install_signal_handlers()
            while self.stop_event is not None and not self.stop_event.wait(0.25):
                pass
        finally:
            self.stop()

    def stop(self) -> None:
        if self.stop_event is not None:
            self.stop_event.set()
        if self.raw_reader is not None:
            self.raw_reader.join(timeout=2.0)
        if self.raw_reader_left is not None:
            self.raw_reader_left.join(timeout=2.0)
        if self.keep_alive_manager is not None:
            self.keep_alive_manager.join(timeout=2.0)
        if self.ipc_bridge is not None:
            self.ipc_bridge.join(timeout=2.0)
        if self.key_mapper_right is not None:
            self.key_mapper_right.release_all()
        if self.key_mapper_left is not None:
            self.key_mapper_left.release_all()
        try:
            pygame.joystick.quit()
            pygame.display.quit()
        finally:
            self._started = False
        self._output("Clean exit. All keys released.")

    def record_input_event(self, button: str, phase: str) -> None:
        """Keep a short event history so the native onboarding can observe real presses."""
        with self._input_event_lock:
            self._input_event_sequence += 1
            self._input_events.append(
                {
                    "sequence": self._input_event_sequence,
                    "button": button,
                    "phase": phase,
                    "timestamp": time.time(),
                }
            )
            del self._input_events[:-64]

    def input_events_snapshot(self) -> list[dict]:
        with self._input_event_lock:
            return list(self._input_events)

    def set_paused(self, paused: bool) -> None:
        """Pausing/resuming is a global switch -- it applies to both
        controllers together, not a per-side setting."""
        if self.key_mapper_right is not None:
            self.key_mapper_right.set_paused(paused)
        if self.key_mapper_left is not None:
            self.key_mapper_left.set_paused(paused)

    def reload_config(self) -> dict:
        """Reload the persisted config and apply it to both mappers without
        restarting -- each rebuilds from its own profile (single_right /
        single_left); neither depends on the other or on any detected
        connection mode."""
        config_path = self.config_path or get_platform_config_path()
        updated = load_config(config_path)

        self.config.clear()
        self.config.update(updated)
        stick_enabled = bool(self.config.get("stick_enabled", True))
        if self.key_mapper_right is not None:
            self.key_mapper_right.switch_profile(self.config, "single_right")
            self.key_mapper_right._stick_enabled = stick_enabled
        if self.key_mapper_left is not None:
            self.key_mapper_left.switch_profile(self.config, "single_left")
            self.key_mapper_left._stick_enabled = stick_enabled

        return {"config_path": config_path}

    def _install_signal_handlers(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            return

        def request_stop(_signum, _frame) -> None:
            if self.stop_event is not None:
                self.stop_event.set()

        signal.signal(signal.SIGTERM, request_stop)
        signal.signal(signal.SIGINT, request_stop)
