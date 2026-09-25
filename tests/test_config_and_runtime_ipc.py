from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from src import runtime_ipc
from src.config_loader import REQUIRED_PROFILES, get_profile, load_config, save_config

# Runtime reload does not use HID, but importing the runtime normally loads the
# hardware adapters. Keep this regression test runnable without real HID
# hardware. Stubbing sys.modules["hid"] via patch.dict here (instead of a
# plain assignment) would restore sys.modules to its pre-`with` snapshot on
# exit, which also discards every module transitively imported in between —
# including pyobjc's `objc` extension, which cannot be re-imported afterwards
# ("Reload of objc._objc detected"). Set the stub directly and leave it.
if "hid" not in sys.modules:
    sys.modules["hid"] = Mock()

with patch.dict(os.environ, {"JOYHARNESS_INPUT_BACKEND": "native"}):
    from src.battery_reader import battery_label
    from src.runtime import JoyHarnessRuntime


class ConfigIsSingleSourceOfTruthTests(unittest.TestCase):
    """The config file is the whole truth: nothing is filled in behind it.

    These lock in the property the app lost once before -- mappings were
    deep-merged over a compiled-in default table, so a config that was
    missing an entry (or a whole profile) silently ran something the
    mapping editor never displayed, and shipped fixes never reached the
    installed file.
    """

    def test_shipped_config_defines_both_sides_completely(self) -> None:
        config = load_config()
        for mode in REQUIRED_PROFILES:
            mappings = get_profile(config, mode)["mappings"]
            self.assertTrue(mappings["buttons"], f"{mode} has no button mappings")
            for direction in ("up", "down", "left", "right"):
                self.assertIn(direction, mappings["stick_directions"])

    def test_missing_profile_is_rejected_not_substituted(self) -> None:
        config = load_config()
        del config["profiles"]["single_left"]
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            target.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaises(ValueError) as ctx:
                load_config(str(target))
            self.assertIn("single_left", str(ctx.exception))

    def test_missing_button_is_rejected_not_defaulted(self) -> None:
        config = load_config()
        del config["profiles"]["single_left"]["mappings"]["buttons"]["ZL"]
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            target.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaises(ValueError) as ctx:
                load_config(str(target))
            self.assertIn("ZL", str(ctx.exception))

    def test_get_profile_never_falls_back_to_the_other_side(self) -> None:
        config = load_config()
        with self.assertRaises(KeyError):
            get_profile(config, "dual")

    def test_left_and_right_profiles_are_independent(self) -> None:
        """Editing one side must not read back on the other."""
        config = load_config()
        left = get_profile(config, "single_left")["mappings"]["buttons"]
        right = get_profile(config, "single_right")["mappings"]["buttons"]
        left["A"] = {"action": "tap", "key": "f13"}
        self.assertNotEqual(right["A"], left["A"])


class PassthroughAndGestureTests(unittest.TestCase):
    """A button is either the key itself, or a split into gestures.

    These pin the two behaviours apart, because the difference is exactly
    what the card and the editor render: a passthrough button fires on
    press and repeats while held (like the keyboard key it stands for),
    while a split button fires its short action on *release*, since until
    then there is no way to know it is not going to become a long press.
    """

    def setUp(self) -> None:
        from src import key_mapper as km

        self.emitted: list[tuple] = []
        self.real_output = km.keyboard_output
        stub = SimpleNamespace(
            press=lambda k: self.emitted.append(("press", k)),
            release=lambda k: self.emitted.append(("release", k)),
            tap=lambda k, duration=0.02: self.emitted.append(("tap", k)),
            send_combination=lambda keys, hold=0.05: self.emitted.append(("combo", "+".join(keys))),
            release_all=lambda: self.emitted.append(("release_all",)),
        )
        km.keyboard_output = stub
        self.mapper = km.KeyMapper(load_config(), mode="single_right")
        self.mapper._repeat_delay = 0.01
        self.mapper._repeat_interval = 0.01

    def tearDown(self) -> None:
        from src import key_mapper as km

        km.keyboard_output = self.real_output

    def test_plain_key_fires_on_press_and_repeats_while_held(self) -> None:
        self.mapper.button_down_name("B")           # ⌫
        self.assertEqual(self.emitted, [("tap", "backspace")])

        time.sleep(0.03)
        self.mapper.poll()
        self.assertEqual(self.emitted.count(("tap", "backspace")), 2)

        self.emitted.clear()
        self.mapper.button_up_name("B")
        self.assertEqual(self.emitted, [], "a repeated key leaves nothing held")

    def test_modifier_is_held_and_never_repeats(self) -> None:
        self.mapper.button_down_name("R")           # right ⌥
        self.assertEqual(self.emitted, [("press", "alt_r")])

        time.sleep(0.05)
        self.mapper.poll()
        self.assertEqual(self.emitted, [("press", "alt_r")], "a keyboard does not repeat a held ⌥")

        self.mapper.button_up_name("R")
        self.assertEqual(self.emitted[-1], ("release", "alt_r"))

    def test_combination_holds_its_modifier_and_repeats_the_rest(self) -> None:
        self.mapper.button_down_name("Home")        # ⌘Space
        self.assertEqual(self.emitted, [("press", "cmd"), ("tap", "space")])

        time.sleep(0.03)
        self.mapper.poll()
        self.assertEqual(self.emitted[-1], ("tap", "space"))
        self.assertEqual(self.emitted.count(("press", "cmd")), 1, "⌘ stays down across repeats")

        self.mapper.button_up_name("Home")
        self.assertEqual(self.emitted[-1], ("release", "cmd"))

    def test_split_button_emits_nothing_until_release(self) -> None:
        self.mapper.button_down_name("A")           # 单击 ↩ / 长按 ⇧↩
        self.assertEqual(self.emitted, [], "a short press is only known once the button comes back up")

        self.mapper.button_up_name("A")
        self.assertEqual(self.emitted, [("combo", "enter")])

    def test_split_button_long_press_replaces_the_short_action(self) -> None:
        self.mapper.button_down_name("A")
        time.sleep(0.40)
        self.mapper.poll()
        self.mapper.button_up_name("A")
        self.assertEqual(self.emitted, [("combo", "shift+enter")])

    def test_stick_direction_repeats_like_an_arrow_key(self) -> None:
        self.mapper.stick_direction("down")
        self.assertEqual(self.emitted, [("tap", "down")])

        time.sleep(0.03)
        self.mapper.poll()
        self.assertEqual(self.emitted.count(("tap", "down")), 2)

        self.emitted.clear()
        self.mapper.stick_centered()
        self.assertEqual(self.emitted, [])

    def test_per_key_repeat_is_rejected(self) -> None:
        """Repeat timing comes from System Settings, so a value here would
        be ignored -- and silently disagreeing with the app is the failure
        mode this whole config format exists to prevent."""
        config = load_config()
        config["profiles"]["single_right"]["mappings"]["buttons"]["B"]["repeat"] = 100
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            target.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaises(ValueError) as ctx:
                load_config(str(target))
            self.assertIn("repeat", str(ctx.exception))


class IdleSleepTests(unittest.TestCase):
    """Reading input requires standard report mode, which streams ~60
    reports/sec and keeps the radio busy, so a connected Joy-Con never idles
    out on its own. The only way it sleeps is if we ask it to."""

    SLEEP_SUBCOMMAND = bytes([0x06, 0x00])

    def _reader(self, minutes, device_factory, stop, sent):
        from src import side_button_reader as sbr

        sbr._POST_SLEEP_GRACE = 0.05

        class Mapper:
            def set_haptic(self, callback) -> None: ...
            def button_down_name(self, name: str) -> None: ...
            def button_up_name(self, name: str) -> None: ...
            def poll(self) -> None: ...
            def release_all(self) -> None: ...
            def stick_direction(self, d: str) -> None: ...
            def stick_centered(self) -> None: ...

        reader = sbr.RawJoyConReader(
            stop, Mapper(), {"poll_interval": 0.001, "idle_sleep_minutes": minutes}, side="R"
        )
        reader._open_joycon = device_factory
        return reader

    @staticmethod
    def _report(pressed: bool) -> list[int]:
        return [0x30, 0, 0x90, 0x08 if pressed else 0x00, 0, 0] + [0x00, 0x08, 0x80] * 2

    def test_idle_controller_is_asked_to_sleep(self) -> None:
        sent: list[bytes] = []
        test = self

        class Quiet:
            def read(self, size: int, timeout_ms: int = 50) -> list[int]:
                return test._report(False)

            def write(self, data) -> None:
                sent.append(bytes(data)[-2:])

            def close(self) -> None: ...

        stop = threading.Event()
        opened = {"count": 0}

        def open_once():
            opened["count"] += 1
            if opened["count"] == 1:
                return Quiet()
            stop.set()
            return None

        reader = self._reader(0.008, open_once, stop, sent)
        reader._loop()

        self.assertIn(self.SLEEP_SUBCOMMAND, sent, "never asked the controller to sleep")
        self.assertTrue(reader.asleep)
        self.assertEqual(reader.battery_state[0], "asleep",
                         "a sleeping controller must not report as disconnected")

    def test_input_keeps_the_controller_awake(self) -> None:
        sent: list[bytes] = []
        test = self

        class Busy:
            def __init__(self) -> None:
                self.reads = 0

            def read(self, size: int, timeout_ms: int = 50) -> list[int]:
                self.reads += 1
                return test._report(self.reads % 8 < 4)

            def write(self, data) -> None:
                sent.append(bytes(data)[-2:])

            def close(self) -> None: ...

        stop = threading.Event()
        reader = self._reader(0.008, lambda: Busy(), stop, sent)
        thread = threading.Thread(target=reader._loop)
        thread.start()
        time.sleep(1.2)            # 2.5x the idle threshold, with presses throughout
        stop.set()
        thread.join(timeout=5)

        self.assertNotIn(self.SLEEP_SUBCOMMAND, sent,
                         "slept while the user was actively pressing buttons")

    def test_sleeping_is_off_unless_configured(self) -> None:
        sent: list[bytes] = []
        test = self

        class Quiet:
            def read(self, size: int, timeout_ms: int = 50) -> list[int]:
                return test._report(False)

            def write(self, data) -> None:
                sent.append(bytes(data)[-2:])

            def close(self) -> None: ...

        stop = threading.Event()
        reader = self._reader(0, lambda: Quiet(), stop, sent)
        thread = threading.Thread(target=reader._loop)
        thread.start()
        time.sleep(0.8)
        stop.set()
        thread.join(timeout=5)

        self.assertNotIn(self.SLEEP_SUBCOMMAND, sent,
                         "slept even though idle_sleep_minutes was 0")

    def test_negative_idle_sleep_is_rejected(self) -> None:
        config = load_config()
        config["idle_sleep_minutes"] = -5
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            target.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaises(ValueError) as ctx:
                load_config(str(target))
            self.assertIn("idle_sleep_minutes", str(ctx.exception))


class OutputHoldTests(unittest.TestCase):
    """The onboarding button test teaches presses that are themselves mapped
    to real shortcuts, so following the instructions used to also fire fn,
    paste, or send a message. Output is held while it teaches -- but that hold
    belongs to the sheet, not the user, so unlike a pause it must leave no
    trace to come back paused from."""

    def setUp(self) -> None:
        runtime_ipc.IPC_DIR.mkdir(parents=True, exist_ok=True)
        runtime_ipc.PAUSE_FILE.unlink(missing_ok=True)
        self.calls: list[bool] = []

        self.allowed: list = []
        self.buzz_calls: list[bool] = []
        mapper = SimpleNamespace(paused=False, output_held=False)

        class FakeRuntime:
            stop_event = threading.Event()
            connection_mode = "none"
            key_mapper = mapper
            raw_reader = None
            raw_reader_left = None

            def set_paused(_self, value: bool) -> None:
                self.calls.append(value)
                mapper.paused = value
                mapper.output_held = value or mapper.output_held

            def set_allowed_buttons(_self, buttons) -> None:
                self.allowed.append(buttons)

            def buzz(_self, long: bool = False) -> list:
                self.buzz_calls.append(long)
                return ["R"]

            def input_events_snapshot(_self) -> list:
                return []

        self.bridge = runtime_ipc.RuntimeIpcBridge(FakeRuntime())

    def tearDown(self) -> None:
        runtime_ipc.PAUSE_FILE.unlink(missing_ok=True)

    def test_hold_suspends_output_without_persisting(self) -> None:
        result = self.bridge._execute_command("hold_output", {"held": True})
        self.assertEqual(result, {"held": True})
        self.assertEqual(self.calls, [True], "output was not actually suspended")
        self.assertFalse(
            runtime_ipc.PAUSE_FILE.exists(),
            "a hold that outlives the app would come back paused for no visible reason",
        )

    def test_pause_does_persist(self) -> None:
        self.bridge._execute_command("set_paused", {"paused": True})
        self.assertTrue(runtime_ipc.PAUSE_FILE.exists(),
                        "an explicit pause is the user's choice and must survive")

    def test_status_reports_the_user_choice_not_the_hold(self) -> None:
        """A hold must not read back as "the user paused this".

        The app restores the pre-onboarding state on the way out, so if its
        own hold showed up as the user's pause it would decide there was
        nothing to restore and leave output suspended.
        """
        self.bridge._execute_command("hold_output", {"held": True})
        self.bridge._publish_status()
        published = json.loads(runtime_ipc.STATUS_FILE.read_text(encoding="utf-8"))
        self.assertFalse(published["paused"], "a transient hold was reported as a user pause")
        self.assertTrue(published["output_held"], "the hold must still be observable")

        self.bridge._execute_command("set_paused", {"paused": True})
        self.bridge._publish_status()
        published = json.loads(runtime_ipc.STATUS_FILE.read_text(encoding="utf-8"))
        self.assertTrue(published["paused"], "an explicit pause must be reported")

    def test_hold_requires_a_boolean(self) -> None:
        with self.assertRaises(ValueError):
            self.bridge._execute_command("hold_output", {"held": "yes"})

    def test_hold_with_allow_lets_the_taught_key_through(self) -> None:
        """The key steps need X to really focus and B to really delete."""
        self.bridge._execute_command("hold_output", {"held": True, "allow": ["X"]})
        self.assertEqual(self.allowed[-1], ["X"])
        self.assertEqual(self.calls, [False], "an allow-list hold must not pause everything")

    def test_release_restores_the_users_own_pause(self) -> None:
        """Someone who had paused before the walkthrough is still paused after it."""
        self.bridge._execute_command("set_paused", {"paused": True})
        self.bridge._execute_command("hold_output", {"held": True, "allow": ["ZR"]})
        self.bridge._execute_command("hold_output", {"held": False})
        self.assertIsNone(self.allowed[-1])
        self.assertEqual(self.calls[-1], True)

        runtime_ipc.PAUSE_FILE.unlink(missing_ok=True)
        self.bridge._execute_command("hold_output", {"held": False})
        self.assertEqual(self.calls[-1], False)

    def test_allow_must_be_button_names(self) -> None:
        with self.assertRaises(ValueError):
            self.bridge._execute_command("hold_output", {"held": True, "allow": "X"})

    def test_buzz_reports_who_felt_it(self) -> None:
        result = self.bridge._execute_command("buzz", {"long": True})
        self.assertEqual(result, {"buzzed": ["R"]})
        self.assertEqual(self.buzz_calls, [True])


class HapticTests(unittest.TestCase):
    """A buzz should tell you something you cannot otherwise know.

    Holding a button is the one moment with no feedback at all -- nothing on
    screen says when the long press took, so you either guess or hold longer
    than needed. Every other moment already has feedback: the keystroke lands.
    Buzzing on those would be a keyboard that vibrates on every key.
    """

    def setUp(self) -> None:
        from src import key_mapper as km

        self.real_output = km.keyboard_output
        km.keyboard_output = SimpleNamespace(
            press=lambda k: None,
            release=lambda k: None,
            tap=lambda k, duration=0.02: None,
            send_combination=lambda keys, hold=0.05: None,
            release_all=lambda: None,
            focus_input=lambda: None,
        )
        self.mapper = km.KeyMapper(load_config(), mode="single_right")
        self.buzzes: list[int] = []
        self.mapper.set_haptic(lambda: self.buzzes.append(1))

    def tearDown(self) -> None:
        from src import key_mapper as km

        km.keyboard_output = self.real_output

    def test_long_press_buzzes_once_when_it_takes(self) -> None:
        self.mapper.button_down_name("A")          # 单击 ↩ / 长按 ⇧↩
        time.sleep(0.40)
        self.mapper.poll()
        self.mapper.poll()                          # a second poll must not repeat it
        self.mapper.button_up_name("A")
        self.assertEqual(len(self.buzzes), 1)

    def test_a_tap_does_not_buzz(self) -> None:
        self.mapper.button_down_name("A")
        self.mapper.button_up_name("A")
        self.assertEqual(self.buzzes, [])

    def test_allowed_buttons_gate_everything_else(self) -> None:
        from src import key_mapper as km

        sent: list = []
        km.keyboard_output.tap = lambda k, duration=0.02: sent.append(k)
        km.keyboard_output.press = lambda k: sent.append(k)
        self.mapper.set_allowed_buttons(["B"])
        self.mapper.button_down_name("Y")          # ⌘Tab would leave the window
        self.mapper.button_up_name("Y")
        self.assertEqual(sent, [], "a button outside the lesson still fired")
        self.mapper.button_down_name("B")
        self.mapper.button_up_name("B")
        self.assertTrue(sent, "the taught button did nothing")
        self.assertTrue(self.mapper.output_held)
        self.mapper.set_allowed_buttons(None)
        self.assertFalse(self.mapper.output_held)

    def test_a_plain_key_never_buzzes(self) -> None:
        self.mapper.button_down_name("B")          # passthrough ⌫
        self.mapper.poll()
        self.mapper.button_up_name("B")
        self.assertEqual(self.buzzes, [])


class ThreadSurvivalTests(unittest.TestCase):
    """A daemon thread that raises dies silently and takes its job with it.

    Both of these have failed this way before: a malformed mapping killed one
    side's reader for the life of the process while the other side kept
    working, and the IPC thread is the only writer of status.json -- losing it
    means the app can never learn the runtime's state again.
    """

    def test_reader_reopens_after_an_unexpected_error(self) -> None:
        from src import side_button_reader as sbr

        raised = {"count": 0}

        class ExplodingMapper:
            def set_haptic(self, callback) -> None: ...

            def button_down_name(self, name: str) -> None:
                raised["count"] += 1
                raise RuntimeError("malformed mapping")

            def button_up_name(self, name: str) -> None: ...
            def poll(self) -> None: ...
            def release_all(self) -> None: ...

        class FakeDevice:
            def __init__(self) -> None:
                self.reads = 0

            def read(self, size: int, timeout_ms: int = 50) -> list[int]:
                self.reads += 1
                if self.reads > 2:
                    raise OSError("link dropped")
                return [0x30, 0, 0x90] + [0xFF] * 12

            def write(self, data: bytes) -> None: ...
            def close(self) -> None: ...

        stop = threading.Event()
        reader = sbr.RawJoyConReader(stop, ExplodingMapper(), {"poll_interval": 0.001}, side="R")
        opens = {"count": 0}

        def fake_open():
            opens["count"] += 1
            if opens["count"] > 3:
                stop.set()
                return None
            return FakeDevice()

        reader._open_joycon = fake_open
        reader._loop()

        self.assertGreater(raised["count"], 0, "the mapper never actually failed")
        self.assertGreater(opens["count"], 2, "reader gave up instead of reopening")

    def test_ipc_thread_survives_a_failed_publish(self) -> None:
        calls = {"count": 0}

        class BareRuntime:
            stop_event = threading.Event()
            connection_mode = "none"
            key_mapper = None
            raw_reader = None
            raw_reader_left = None

            def input_events_snapshot(self) -> list:
                return []

        runtime = BareRuntime()
        runtime.stop_event.clear()
        bridge = runtime_ipc.RuntimeIpcBridge(runtime)

        def flaky(running: bool = True) -> None:
            calls["count"] += 1
            if calls["count"] <= 3:
                raise OSError("no space left on device")
            if calls["count"] >= 6:
                runtime.stop_event.set()

        bridge._publish_status = flaky
        bridge._consume_pause_command = lambda: None
        bridge._consume_command = lambda: None

        thread = threading.Thread(target=bridge._loop)
        thread.start()
        thread.join(timeout=10)

        self.assertFalse(thread.is_alive(), "IPC loop did not finish")
        self.assertGreaterEqual(calls["count"], 6, "IPC thread died on the first failure")


class ControllerGeometryTests(unittest.TestCase):
    """Lock in how the two controllers mirror each other.

    Every left-hand mapping mirrors the right hand *by position*, never by
    button name. The rail buttons are where that distinction bites: rotate
    a Joy-Con into its sideways grip and the rail becomes the top edge, so
    SL is the left shoulder and SR the right one. The left Joy-Con rotates
    counter-clockwise (its rail is on the right edge), which puts SL at the
    top; the right one rotates clockwise, putting SR at the top. Mirroring
    by name instead put Esc on the left controller's lower rail button
    while the UI drew it on the upper one.
    """

    # right-hand button -> the left-hand button in the same physical place
    POSITIONAL_PAIRS = (
        ("SR", "SL"),      # upper rail button on each side
        ("SL", "SR"),      # lower rail button on each side
        ("R", "L"),        # shoulder
        ("ZR", "ZL"),      # trigger
        ("Plus", "Minus"),
        ("RStick", "LStick"),
        ("Home", "Capture"),
        ("X", "X"), ("A", "A"), ("B", "B"), ("Y", "Y"),
    )

    HOTSPOTS = (
        Path(__file__).resolve().parent.parent
        / "assets" / "controller" / "hotspots.json"
    )

    def test_left_mirrors_right_by_position(self) -> None:
        config = load_config()
        right = get_profile(config, "single_right")["mappings"]["buttons"]
        left = get_profile(config, "single_left")["mappings"]["buttons"]
        for right_name, left_name in self.POSITIONAL_PAIRS:
            self.assertEqual(
                right[right_name],
                left[left_name],
                f"right {right_name} and left {left_name} are the same physical "
                f"position and must carry the same mapping",
            )

    def test_rail_buttons_are_drawn_where_they_physically_are(self) -> None:
        points = json.loads(self.HOTSPOTS.read_text(encoding="utf-8"))["points"]
        self.assertLess(
            points["right"]["SR"]["y"], points["right"]["SL"]["y"],
            "right Joy-Con: SR is the upper rail button",
        )
        self.assertLess(
            points["left"]["SL"]["y"], points["left"]["SR"]["y"],
            "left Joy-Con: SL is the upper rail button -- mirroring the right "
            "side's coordinates by x alone gets this backwards",
        )

    def test_every_mapped_button_has_a_hotspot(self) -> None:
        points = json.loads(self.HOTSPOTS.read_text(encoding="utf-8"))["points"]
        config = load_config()
        for mode, side in (("single_right", "right"), ("single_left", "left")):
            buttons = set(get_profile(config, mode)["mappings"]["buttons"])
            # The UI labels the sticks and a few buttons in Chinese; compare
            # on count plus the rail/shoulder names the tables share.
            self.assertEqual(len(points[side]), len(buttons))
            for name in ("SL", "SR"):
                self.assertIn(name, points[side])


class ConfigSaveTests(unittest.TestCase):
    def test_save_is_validated_atomic_and_backed_up(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            original = load_config()
            save_config(original, str(target))
            updated = copy.deepcopy(original)
            updated["deadzone"] = 0.42
            save_config(updated, str(target))

            stored = json.loads(target.read_text(encoding="utf-8"))
            self.assertEqual(stored["deadzone"], 0.42)
            backups = list((target.parent / "backups").glob("user-*.json"))
            self.assertEqual(len(backups), 1)
            backup = json.loads(backups[0].read_text(encoding="utf-8"))
            self.assertEqual(backup["deadzone"], original["deadzone"])
            self.assertEqual(list(target.parent.glob(".user.json.*.tmp")), [])

    def test_invalid_config_does_not_replace_existing_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            target.write_text('{"sentinel": true}\n', encoding="utf-8")
            invalid = load_config()
            invalid["deadzone"] = 2
            with self.assertRaises(ValueError):
                save_config(invalid, str(target))
            self.assertEqual(target.read_text(encoding="utf-8"), '{"sentinel": true}\n')
            self.assertFalse((target.parent / "backups").exists())


class RuntimeConfigReloadTests(unittest.TestCase):
    def test_reload_reuses_explicit_startup_config_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "user.json"
            initial = load_config()
            initial["deadzone"] = 0.23
            save_config(initial, str(target))

            runtime = JoyHarnessRuntime(
                load_config(str(target)),
                config_path=str(target),
            )
            updated = copy.deepcopy(initial)
            updated["deadzone"] = 0.61
            save_config(updated, str(target))

            result = runtime.reload_config()
            self.assertEqual(runtime.config["deadzone"], 0.61)
            self.assertEqual(result["config_path"], str(target))


class FakeRuntime:
    def __init__(self) -> None:
        self.stop_event = threading.Event()
        self.paused_calls: list[bool] = []
        self.reload_calls = 0
        self.battery_reader = None
        self.connection_mode = "single_right"
        self.key_mapper = None
        self.raw_reader = None
        self.input_events = []

    def input_events_snapshot(self) -> list[dict]:
        return list(self.input_events)

    def set_paused(self, paused: bool) -> None:
        self.paused_calls.append(paused)

    def reload_config(self) -> dict:
        self.reload_calls += 1
        return {"active_profile": "single_right"}


class RuntimeIpcTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.ipc_dir = Path(self.tempdir.name)
        self.patches = [
            patch.object(runtime_ipc, "IPC_DIR", self.ipc_dir),
            patch.object(runtime_ipc, "STATUS_FILE", self.ipc_dir / "status.json"),
            patch.object(runtime_ipc, "PAUSE_FILE", self.ipc_dir / "paused"),
            patch.object(runtime_ipc, "COMMAND_FILE", self.ipc_dir / "command.json"),
            patch.object(runtime_ipc, "COMMAND_RESULT_FILE", self.ipc_dir / "command-result.json"),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self) -> None:
        for item in reversed(self.patches):
            item.stop()
        self.tempdir.cleanup()

    def write_command(self, command_id: str, command_type: str, payload=None) -> None:
        runtime_ipc.ensure_ipc_dir()
        runtime_ipc.COMMAND_FILE.write_text(
            json.dumps({"id": command_id, "type": command_type, "payload": payload}),
            encoding="utf-8",
        )

    def result(self) -> dict:
        return json.loads(runtime_ipc.COMMAND_RESULT_FILE.read_text(encoding="utf-8"))

    def test_pause_command_returns_confirmation_and_is_not_replayed(self) -> None:
        runtime = FakeRuntime()
        bridge = runtime_ipc.RuntimeIpcBridge(runtime)
        self.write_command("request-1", "set_paused", {"paused": True})
        bridge._consume_command()
        self.assertEqual(runtime.paused_calls, [True])
        self.assertTrue(runtime_ipc.PAUSE_FILE.exists())
        self.assertEqual(self.result()["result"], {"paused": True})
        self.assertFalse(runtime_ipc.COMMAND_FILE.exists())

        self.write_command("request-1", "set_paused", {"paused": False})
        bridge._consume_command()
        self.assertEqual(runtime.paused_calls, [True])

    def test_reload_and_invalid_command_report_results(self) -> None:
        runtime = FakeRuntime()
        bridge = runtime_ipc.RuntimeIpcBridge(runtime)
        self.write_command("request-2", "reload_config")
        bridge._consume_command()
        self.assertTrue(self.result()["ok"])
        self.assertEqual(runtime.reload_calls, 1)

        self.write_command("request-3", "unknown")
        bridge._consume_command()
        result = self.result()
        self.assertFalse(result["ok"])
        self.assertIn("Unsupported command", result["error"])

    def test_controller_payload_comes_only_from_that_sides_reader(self) -> None:
        """Each side reports its own reader's state and nothing else: a
        controller counts as connected only while its reader is actually
        receiving input reports."""
        runtime = FakeRuntime()
        runtime.raw_reader = SimpleNamespace(connected=False, battery_state=("discharging", 3))
        runtime.raw_reader_left = SimpleNamespace(connected=True, battery_state=("discharging", 1))

        # Right reader is down -> disconnected, even though it last saw a battery level.
        self.assertEqual(runtime_ipc._controller_payload(runtime, "R"), ["disconnected", -1])
        # ...and the left side is unaffected by the right side's state.
        self.assertEqual(runtime_ipc._controller_payload(runtime, "L"), ["discharging", 1])

        runtime.raw_reader.connected = True
        self.assertEqual(runtime_ipc._controller_payload(runtime, "R"), ["discharging", 3])

        # Connected but no battery reading decoded yet.
        runtime.raw_reader.battery_state = ("unknown", -1)
        self.assertEqual(runtime_ipc._controller_payload(runtime, "R"), ["connected", -1])

    def test_status_publishes_recent_input_events(self) -> None:
        runtime = FakeRuntime()
        runtime.input_events = [
            {"sequence": 7, "button": "Plus", "phase": "down", "timestamp": 123.0},
            {"sequence": 8, "button": "Plus", "phase": "up", "timestamp": 123.4},
        ]
        bridge = runtime_ipc.RuntimeIpcBridge(runtime)
        bridge._publish_status()
        payload = json.loads(runtime_ipc.STATUS_FILE.read_text(encoding="utf-8"))
        self.assertEqual(payload["input_events"], runtime.input_events)

    def test_raw_reader_reports_button_transitions(self) -> None:
        with patch.dict(sys.modules, {"hid": Mock()}):
            from src.side_button_reader import RawJoyConReader

        mapper = Mock()
        events = []
        reader = RawJoyConReader(threading.Event(), mapper, {}, on_input=lambda *event: events.append(event))
        neutral = [0] * 12
        pressed = list(neutral)
        pressed[3] = 1 << 7  # ZR

        reader._handle_buttons(neutral)
        reader._handle_buttons(pressed)
        reader._handle_buttons(neutral)

        self.assertEqual(events, [("ZR", "down"), ("ZR", "up")])
        mapper.button_down_name.assert_called_once_with("ZR")
        mapper.button_up_name.assert_called_once_with("ZR")

    def test_joycon_power_field_uses_discrete_levels(self) -> None:
        self.assertEqual(battery_label(0x00), ("discharging", 0))
        self.assertEqual(battery_label(0x03), ("charging", 1))
        self.assertEqual(battery_label(0x06), ("discharging", 3))
        self.assertEqual(battery_label(0x09), ("charging", 4))
        self.assertEqual(battery_label(0x0F), ("unknown", -1))

    def test_corrupt_command_is_discarded(self) -> None:
        runtime_ipc.ensure_ipc_dir()
        runtime_ipc.COMMAND_FILE.write_text("{broken", encoding="utf-8")
        runtime_ipc.RuntimeIpcBridge(FakeRuntime())._consume_command()
        self.assertFalse(runtime_ipc.COMMAND_FILE.exists())


if __name__ == "__main__":
    unittest.main()
