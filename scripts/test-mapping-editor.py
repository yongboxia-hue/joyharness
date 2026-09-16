#!/usr/bin/env python3
"""Drive the 按键 editor the way a person does, and read back what it wrote.

Every other check in this repo reads source or asserts that a control exists.
None of them press the control and look at the file afterwards, which is the
only way to know that changing a shortcut changes the shortcut: the editor
could render perfectly, save nothing, and every existing check would pass.

So this one runs the app. It clicks the ZR card, types a shortcut, records
another one with real key events, clears it, restores the recommendation, and
cancels out of an edit -- checking config/user.json after each, because that
file is what the runtime reads. The last leg, runtime to keystroke, needs a
Joy-Con in someone's hand and is not automated here.

The config is snapshotted before and restored after, so running this leaves
the preview's mappings exactly as it found them.

Usage: scripts/test-mapping-editor.py      (Preview must be built; it is
                                            launched if not already running)
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import ApplicationServices as AX
import Quartz
from AppKit import NSRunningApplication, NSWorkspace

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "macos-swiftui" / "JoyHarness Preview.app"
BUNDLE_ID = "com.yongboxia.joyharness.preview"
CONFIG = Path.home() / "Applications" / "JoyHarness" / "config" / "user.json"
RUNTIME = ROOT / "build" / "python-runtime" / "dist" / "JoyHarnessRuntime" / "JoyHarnessRuntime"

FAILURES: list[str] = []
CHECKS = 0


def check(ok: bool, label: str, detail: str = "") -> None:
    global CHECKS
    CHECKS += 1
    if ok:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}" + (f"\n       {detail}" if detail else ""))
        FAILURES.append(label)


# --------------------------------------------------------------------------
# Accessibility plumbing
# --------------------------------------------------------------------------
def app_element() -> AX.AXUIElementRef:
    for running in NSWorkspace.sharedWorkspace().runningApplications():
        if running.bundleIdentifier() == BUNDLE_ID:
            return AX.AXUIElementCreateApplication(running.processIdentifier())
    raise SystemExit("JoyHarness Preview is not running")


def attribute(element, name):
    error, value = AX.AXUIElementCopyAttributeValue(element, name, None)
    return value if error == 0 else None


def find(element, identifier: str, depth: int = 0):
    if depth > 40:
        return None
    if attribute(element, "AXIdentifier") == identifier:
        return element
    children = attribute(element, AX.kAXChildrenAttribute) or []
    for child in children:
        found = find(child, identifier, depth + 1)
        if found is not None:
            return found
    return None


def await_element(identifier: str, timeout: float = 4.0):
    """Wait for an element to appear. Sheets animate; polling beats sleeping."""
    app = app_element()
    deadline = time.time() + timeout
    while time.time() < deadline:
        element = find(app, identifier)
        if element is not None:
            return element
        time.sleep(0.1)
        app = app_element()
    raise AssertionError(f"accessibility element never appeared: {identifier}")


def find_role(element, role: str, depth: int = 0):
    if depth > 40:
        return None
    if attribute(element, "AXRole") == role:
        return element
    for child in attribute(element, AX.kAXChildrenAttribute) or []:
        found = find_role(child, role, depth + 1)
        if found is not None:
            return found
    return None


def await_role(role: str, timeout: float = 4.0):
    """SwiftUI does not put an AXIdentifier on a plain TextField, so the one
    text field in the sheet is found by what it is instead."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        element = find_role(app_element(), role)
        if element is not None:
            return element
        time.sleep(0.1)
    raise AssertionError(f"no {role} appeared")


def press(identifier: str) -> None:
    AX.AXUIElementPerformAction(await_element(identifier), AX.kAXPressAction)
    time.sleep(0.35)


def type_text(text: str) -> None:
    """Type into whatever has focus, as keystrokes.

    Setting AXValue on a SwiftUI TextField changes what the field draws
    without telling SwiftUI, so the binding -- and therefore the draft --
    would never see it. Real keys go through the same path a person's do.
    """
    element = await_role("AXTextField")
    point = attribute(element, AX.kAXPositionAttribute)
    size = attribute(element, AX.kAXSizeAttribute)
    _, origin = AX.AXValueGetValue(point, AX.kAXValueCGPointType, None)
    _, extent = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
    spot = Quartz.CGPointMake(origin.x + extent.width / 2, origin.y + extent.height / 2)
    for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        event = Quartz.CGEventCreateMouseEvent(None, event_type, spot, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)
    time.sleep(0.3)

    # Select all, then replace. ⌘A only works because the 编辑 menu exists.
    send_key(0, Quartz.kCGEventFlagMaskCommand)

    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
        Quartz.CGEventKeyboardSetUnicodeString(event, len(text), text)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)
    time.sleep(0.5)


def title_of(identifier: str) -> str:
    element = await_element(identifier)
    for name in ("AXTitle", "AXValue", "AXDescription"):
        value = attribute(element, name)
        if isinstance(value, str) and value:
            return value
    return ""


def frame_of(identifier: str):
    element = await_element(identifier)
    position = attribute(element, AX.kAXPositionAttribute)
    size = attribute(element, AX.kAXSizeAttribute)
    ok_p, point = AX.AXValueGetValue(position, AX.kAXValueCGPointType, None)
    ok_s, extent = AX.AXValueGetValue(size, AX.kAXValueCGSizeType, None)
    if not (ok_p and ok_s):
        raise AssertionError(f"no frame for {identifier}")
    return point, extent


def click(identifier: str) -> None:
    """A real click, for controls that answer to the mouse rather than AXPress.

    The recorder is one: it starts listening in mouseDown, so pressing it
    through accessibility would skip the very thing under test.
    """
    point, size = frame_of(identifier)
    spot = Quartz.CGPointMake(point.x + size.width / 2, point.y + size.height / 2)
    for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        event = Quartz.CGEventCreateMouseEvent(None, event_type, spot, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)
    time.sleep(0.4)


def send_key(keycode: int, flags: int) -> None:
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, keycode, down)
        Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)
    time.sleep(0.4)


# --------------------------------------------------------------------------
# The runtime
# --------------------------------------------------------------------------
def ipc_directory() -> Path:
    plist = APP / "Contents" / "Info.plist"
    out = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :JoyHarnessIPCPath", str(plist)],
        capture_output=True, text=True, check=True,
    )
    return Path(out.stdout.strip())


def start_runtime() -> subprocess.Popen | None:
    """Saving a mapping needs the runtime, and the preview never starts one.

    ConfigStore writes the file and then asks the runtime to take it; when
    nothing answers it puts the old file back, which is why every save in this
    test used to leave the config exactly as it found it. A preview build does
    not bundle a runtime -- that is deliberate, production does -- so the test
    starts the one this repo builds and stops it again afterwards.
    """
    if not RUNTIME.exists():
        raise SystemExit(f"Build the runtime first: scripts/build-python-runtime.sh ({RUNTIME})")

    ipc = ipc_directory()
    ipc.mkdir(parents=True, exist_ok=True)
    status = ipc / "status.json"
    status.unlink(missing_ok=True)

    import os

    environment = dict(os.environ)
    environment["JOYHARNESS_INPUT_BACKEND"] = "native"
    environment["JOYHARNESS_NATIVE_INPUT_SOCKET"] = str(ipc / "input.sock")
    environment["JOYHARNESS_IPC_DIR"] = str(ipc)

    log = open(ROOT / "build" / "mapping-editor-test-runtime.log", "w")
    process = subprocess.Popen(
        [str(RUNTIME), "--native-client", "--no-admin-warn", "--config", str(CONFIG)],
        cwd=str(CONFIG.parent.parent),
        env=environment,
        stdout=log,
        stderr=log,
    )
    deadline = time.time() + 20
    while time.time() < deadline:
        if status.exists():
            time.sleep(0.5)
            return process
        if process.poll() is not None:
            raise SystemExit(
                "The runtime exited immediately; see build/mapping-editor-test-runtime.log"
            )
        time.sleep(0.2)
    process.terminate()
    raise SystemExit("The runtime never reported a status; see build/mapping-editor-test-runtime.log")


# --------------------------------------------------------------------------
# The app
# --------------------------------------------------------------------------
def launch_and_focus() -> None:
    subprocess.run(["open", "-a", str(APP)], check=True)
    time.sleep(3)
    for running in NSWorkspace.sharedWorkspace().runningApplications():
        if running.bundleIdentifier() == BUNDLE_ID:
            running.activateWithOptions_(1 << 1)
    time.sleep(1)

    # Park the window: it is wider than some displays, and a synthetic click
    # aimed past the screen edge lands nowhere at all.
    app = app_element()
    windows = attribute(app, AX.kAXWindowsAttribute) or []
    if windows:
        origin = AX.AXValueCreate(AX.kAXValueCGPointType, Quartz.CGPointMake(20, 40))
        AX.AXUIElementSetAttributeValue(windows[0], AX.kAXPositionAttribute, origin)
        time.sleep(0.5)


def close_any_sheet() -> None:
    """Start every case from the same place.

    The app keeps whatever was on screen when the last run ended -- including
    an open sheet halfway through an edit -- and a test that assumes otherwise
    reports the app broken when it is only where it was left.
    """
    app = app_element()
    if find(app, "mapping-editor-cancel") is not None:
        press("mapping-editor-cancel")
        time.sleep(0.5)


def open_zr_editor() -> None:
    close_any_sheet()
    press("sidebar-mapping")
    time.sleep(0.6)
    press("mapping-card-right-ZR")
    await_element("mapping-editor-save")


def set_input_mode(manual: bool) -> None:
    """Switch to typing or to recording, whichever it is not already on.

    Read from the toggle's own label rather than assumed: pressing it blind
    turns manual entry off just as readily as on.
    """
    label = ""
    deadline = time.time() + 5
    while time.time() < deadline:
        label = attribute(await_element("manual-shortcut-toggle"), "AXDescription") or ""
        if label in ("手动输入", "改用录制"):
            break
        time.sleep(0.15)
    else:
        raise AssertionError("the input-mode toggle never said what it does")

    # Wait for the mode to actually be the one asked for rather than for a
    # fixed number of milliseconds -- the sheet animates, and a test that
    # guesses how long that takes fails on a busy machine and passes on an idle
    # one. The press is repeated rather than trusted once: a sheet that is in
    # the accessibility tree is not necessarily taking presses yet, and the
    # first one lands on nothing often enough to matter.
    for _ in range(4):
        if (find_role(app_element(), "AXTextField") is not None) == manual:
            return
        press("manual-shortcut-toggle")
        deadline = time.time() + 1.5
        while time.time() < deadline:
            if (find_role(app_element(), "AXTextField") is not None) == manual:
                return
            time.sleep(0.15)
    raise AssertionError(f"the editor would not switch to {'typing' if manual else 'recording'}")


def button_config(button: str = "ZR") -> dict | None:
    data = json.loads(CONFIG.read_text(encoding="utf-8"))
    return data["profiles"]["single_right"]["mappings"]["buttons"].get(button)


# --------------------------------------------------------------------------
# The cases
# --------------------------------------------------------------------------
def case_manual_input() -> None:
    print("\n手动输入 -> 保存")
    open_zr_editor()
    set_input_mode(manual=True)
    type_text("Command+Shift+7")
    press("mapping-editor-save")
    time.sleep(0.8)
    check(button_config() == {"action": "passthrough", "keys": ["cmd", "shift", "7"]},
          "typed shortcut reaches the config file", f"{button_config()}")


def case_recording() -> None:
    print("\n录制 -> 保存")
    open_zr_editor()
    set_input_mode(manual=False)
    click("shortcut-recorder")
    # ⌘⌥5: keycode 23 is "5", and both modifiers are set on the event.
    send_key(23, Quartz.kCGEventFlagMaskCommand | Quartz.kCGEventFlagMaskAlternate)
    shown = title_of("shortcut-recorder")
    check(shown == "⌥⌘5" or shown == "⌘⌥5",
          "the recorder shows what was pressed", f"showed {shown!r}")
    press("mapping-editor-save")
    time.sleep(0.8)
    check(button_config() == {"action": "passthrough", "keys": ["cmd", "alt", "5"]},
          "recorded shortcut reaches the config file", f"{button_config()}")


def case_clear() -> None:
    print("\n清空 -> 保存")
    open_zr_editor()
    press("shortcut-clear")
    press("mapping-editor-save")
    time.sleep(0.8)
    current = button_config()
    check(current is None or current.get("action") == "disabled",
          "an emptied field leaves the button doing nothing", f"{current}")


def case_add_long_press() -> None:
    print("\n添加长按 -> 录制 -> 保存")
    open_zr_editor()
    set_input_mode(manual=True)
    type_text("Command+V")
    press("mapping-add-long")
    time.sleep(0.4)
    check(find(app_element(), "mapping-add-long") is None,
          "添加长按 disappears once there is a long press")
    press("mapping-editor-save")
    time.sleep(0.8)
    current = button_config()
    check(isinstance(current, dict) and current.get("action") == "short_long"
          and current.get("short") == {"keys": ["cmd", "v"]},
          "a second gesture makes the mapping a short/long pair", f"{current}")


def case_restore_recommended() -> None:
    print("\n恢复推荐 -> 保存")
    open_zr_editor()
    press("mapping-editor-reset")
    press("mapping-editor-save")
    time.sleep(0.8)
    check(button_config() == {"action": "passthrough", "keys": ["fn"]},
          "恢复推荐 puts the shipped default back", f"{button_config()}")


def case_cancel_writes_nothing() -> None:
    print("\n改了之后取消")
    before = CONFIG.read_text(encoding="utf-8")
    open_zr_editor()
    set_input_mode(manual=True)
    type_text("Control+Option+9")
    press("mapping-editor-cancel")
    time.sleep(0.6)
    check(CONFIG.read_text(encoding="utf-8") == before,
          "取消 leaves the file untouched")


def main() -> int:
    if not APP.exists():
        raise SystemExit(f"Build the preview app first: {APP}")
    if not CONFIG.exists():
        raise SystemExit(f"No preview config at {CONFIG}")

    backup = CONFIG.with_suffix(".json.editor-test-backup")
    shutil.copy2(CONFIG, backup)
    runtime = None
    try:
        runtime = start_runtime()
        launch_and_focus()
        case_manual_input()
        case_recording()
        case_clear()
        case_add_long_press()
        case_restore_recommended()
        case_cancel_writes_nothing()
    finally:
        close_any_sheet()
        if runtime is not None:
            runtime.terminate()
            try:
                runtime.wait(timeout=5)
            except subprocess.TimeoutExpired:
                runtime.kill()
        shutil.copy2(backup, CONFIG)
        backup.unlink()

    print()
    if FAILURES:
        print(f"Mapping editor verification FAILED ({len(FAILURES)} of {CHECKS}):")
        for failure in FAILURES:
            print(f"  - {failure}")
        return 1
    print(f"Mapping editor verification passed ({CHECKS} checks).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
