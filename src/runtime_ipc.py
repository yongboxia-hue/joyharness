"""Small file-based bridge between the macOS menu bar and runtime service."""

from __future__ import annotations

import json
import logging
import os
import tempfile
import threading
import time
from pathlib import Path

IPC_DIR = Path(os.environ.get("JOYHARNESS_IPC_DIR", "")).expanduser() if os.environ.get("JOYHARNESS_IPC_DIR") else Path(tempfile.gettempdir()) / "joyharness-runtime"
STATUS_FILE = IPC_DIR / "status.json"
PAUSE_FILE = IPC_DIR / "paused"
COMMAND_FILE = IPC_DIR / "command.json"
COMMAND_RESULT_FILE = IPC_DIR / "command-result.json"

logger = logging.getLogger(__name__)


def ensure_ipc_dir() -> None:
    IPC_DIR.mkdir(parents=True, exist_ok=True)


class RuntimeIpcBridge:
    """Publishes runtime status and consumes menu commands."""

    def __init__(self, runtime) -> None:
        self._runtime = runtime
        self._thread: threading.Thread | None = None
        self._last_paused: bool | None = None
        self._last_command_id: str | None = None

    def start(self) -> None:
        ensure_ipc_dir()
        self._thread = threading.Thread(
            target=self._loop,
            name="JoyHarnessRuntimeIpcBridge",
            daemon=True,
        )
        self._thread.start()

    def join(self, timeout: float = 2.0) -> None:
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=timeout)

    def _loop(self) -> None:
        while self._runtime.stop_event is not None and not self._runtime.stop_event.is_set():
            # A daemon thread that raises dies silently, and this one is the
            # only thing writing status.json -- losing it means the app can
            # never learn the runtime's state again. A transient failure here
            # (the IPC directory removed, a full disk) has to cost one cycle,
            # not the whole channel.
            try:
                self._publish_status()
                self._consume_pause_command()
                self._consume_command()
            except Exception:
                logger.exception("IPC cycle failed; retrying next tick")
            self._runtime.stop_event.wait(0.5)
        try:
            self._publish_status(running=False)
        except Exception:
            logger.exception("Final status publish failed")

    def _publish_status(self, running: bool = True) -> None:
        ensure_ipc_dir()
        events_snapshot = getattr(self._runtime, "input_events_snapshot", None)
        input_events = events_snapshot() if callable(events_snapshot) else []
        payload = {
            "running": running,
            "connection_mode": self._runtime.connection_mode,
            # The user's own choice, which is what PAUSE_FILE records -- not
            # the mapper's internal flag. A transient hold (the onboarding
            # button test) also stops the mapper, and reporting that as
            # "paused" made the app mistake its own hold for something the
            # user had done, so leaving the test never resumed output.
            "paused": PAUSE_FILE.exists(),
            # Whether output is actually suspended right now, for whatever
            # reason. Usually the same as `paused`; they differ while a
            # transient hold is in effect. Diagnostic only -- the UI shows
            # `paused`, because that is the part the user decided.
            "output_held": bool(self._runtime.key_mapper and self._runtime.key_mapper.paused),
            "battery": {
                "L": _controller_payload(self._runtime, "L"),
                "R": _controller_payload(self._runtime, "R"),
            },
            "input_events": input_events,
        }
        # The scratch file carries this process's pid. A fixed name is shared
        # state: two runtimes each write it, the first replace() moves it, and
        # the second raises FileNotFoundError -- 823 times in the 2026-09-14
        # log. Single-instance locking should now keep runtimes from
        # overlapping at all, but the two do overlap briefly across a restart,
        # and a status write is not worth losing to that.
        tmp = STATUS_FILE.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            tmp.replace(STATUS_FILE)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise

    def _consume_command(self) -> None:
        if not COMMAND_FILE.exists():
            return
        try:
            payload = json.loads(COMMAND_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            logger.warning("Ignoring invalid IPC command: %s", error)
            try:
                COMMAND_FILE.unlink(missing_ok=True)
            except OSError:
                pass
            return

        command_id = str(payload.get("id", "")).strip()
        command_type = str(payload.get("type", "")).strip()
        if not command_id or not command_type or command_id == self._last_command_id:
            return

        self._last_command_id = command_id
        try:
            result = self._execute_command(command_type, payload.get("payload"))
            self._write_command_result(command_id, command_type, ok=True, result=result)
        except Exception as error:
            logger.exception("IPC command failed: %s", command_type)
            self._write_command_result(
                command_id,
                command_type,
                ok=False,
                error=str(error) or error.__class__.__name__,
            )
        finally:
            try:
                COMMAND_FILE.unlink(missing_ok=True)
            except OSError:
                pass

    def _execute_command(self, command_type: str, payload) -> dict:
        if command_type == "ping":
            return {"running": True}
        if command_type == "set_paused":
            if not isinstance(payload, dict) or not isinstance(payload.get("paused"), bool):
                raise ValueError("set_paused requires a boolean payload.paused")
            paused = bool(payload["paused"])
            self._runtime.set_paused(paused)
            if paused:
                PAUSE_FILE.touch()
            else:
                PAUSE_FILE.unlink(missing_ok=True)
            self._last_paused = paused
            return {"paused": paused}
        if command_type == "hold_output":
            # Like set_paused, but deliberately does not touch PAUSE_FILE.
            # The onboarding button test holds output while it teaches, and a
            # hold that outlived the app -- a crash mid-test, say -- would
            # leave the user paused on next launch with no idea why.
            if not isinstance(payload, dict) or not isinstance(payload.get("held"), bool):
                raise ValueError("hold_output requires a boolean payload.held")
            held = bool(payload["held"])
            self._runtime.set_paused(held)
            return {"held": held}
        if command_type == "reload_config":
            result = self._runtime.reload_config()
            self._publish_status()
            return result
        raise ValueError(f"Unsupported command type: {command_type}")

    def _write_command_result(
        self,
        command_id: str,
        command_type: str,
        *,
        ok: bool,
        result: dict | None = None,
        error: str | None = None,
    ) -> None:
        ensure_ipc_dir()
        payload = {
            "id": command_id,
            "type": command_type,
            "ok": ok,
            "result": result or {},
            "error": error,
            "completed_at": time.time(),
        }
        temp = COMMAND_RESULT_FILE.with_name(f".{COMMAND_RESULT_FILE.name}.tmp")
        temp.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
        temp.replace(COMMAND_RESULT_FILE)

    def _consume_pause_command(self) -> None:
        paused = PAUSE_FILE.exists()
        if paused != self._last_paused:
            self._last_paused = paused
            self._runtime.set_paused(paused)


def _controller_payload(runtime, side: str) -> list:
    """Connection + battery for one side, straight from that side's reader.

    Each side has exactly one reader (runtime.raw_reader is always the right
    one, runtime.raw_reader_left always the left one) and it decodes battery
    from the same report stream it is already reading, so it is the single
    source of truth here -- no second opinion to reconcile.
    """
    raw_reader = getattr(runtime, "raw_reader" if side == "R" else "raw_reader_left", None)
    if raw_reader is None:
        return ["disconnected", -1]
    if not raw_reader.connected:
        # A sleeping controller is not a missing one -- it comes back on the
        # next button press, and the UI should say that rather than raise an
        # alarm the user has to investigate.
        return ["asleep" if getattr(raw_reader, "asleep", False) else "disconnected", -1]

    status, level = raw_reader.battery_state
    if str(status) in {"charging", "discharging"} and level >= 0:
        return [status, level]
    return ["connected", -1]
