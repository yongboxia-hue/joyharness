#!/usr/bin/env python3
"""Assert that every fact in this product has one authority, and that every
restatement of it still agrees.

Six of v0.1's eight defects were the same shape: one fact written down in two
or more places, drifting apart afterwards. They all presented identically --
the feature worked, the button responded, and only the label was lying -- so
clicking through the UI found none of them. What finds them is naming the
authority for each fact and checking the copies against it.

Sections 1-7 below follow the project's fact/authority table. Section 8
keeps the older "this affordance still exists" checks, which are cheap and
occasionally catch a deletion; section 9 guards the fixes whose failure mode is
to quietly come back.

A check here must fail when the *behaviour* regresses, not merely when a line
of code is renamed. `let maxColumnCount = max(...)` was asserted by name for
months as the "uniform column spacing" contract while the value it named was
computed and never read.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "macos" / "JoyHarnessNative"
sys.path.insert(0, str(ROOT))

FAILURES: list[str] = []
CHECKS = 0


def check(ok: bool, label: str, detail: str = "") -> None:
    global CHECKS
    CHECKS += 1
    if not ok:
        FAILURES.append(f"{label}\n      {detail}" if detail else label)


def require(source: str, token: str, label: str) -> None:
    check(token in source, f"Missing native UI contract: {label}")


def forbid(source: str, token: str, label: str) -> None:
    check(token not in source, label)


def read(*parts: str) -> str:
    return ROOT.joinpath(*parts).read_text(encoding="utf-8")


app_model = read("macos", "JoyHarnessNative", "AppModel.swift")
root_view = read("macos", "JoyHarnessNative", "RootView.swift")
mapping_view = read("macos", "JoyHarnessNative", "MappingView.swift")
connection_view = read("macos", "JoyHarnessNative", "ConnectionView.swift")
mapping_config = read("macos", "JoyHarnessNative", "MappingConfig.swift")
mapping_editor = read("macos", "JoyHarnessNative", "MappingEditor.swift")
action_catalog = read("macos", "JoyHarnessNative", "ActionCatalog.swift")
design = read("macos", "JoyHarnessNative", "DesignSystem.swift")
about_view = read("macos", "JoyHarnessNative", "AboutView.swift")
onboarding_view = read("macos", "JoyHarnessNative", "OnboardingView.swift")
runtime_manager = read("macos", "JoyHarnessNative", "RuntimeManager.swift")
status_bar = read("macos", "JoyHarnessNative", "StatusBarController.swift")
menu_bar_icon = read("macos", "JoyHarnessNative", "MenuBarIcon.swift")
config_store = read("macos", "JoyHarnessNative", "ConfigStore.swift")
build_script = read("scripts", "build-swiftui-macos-app.sh")
runtime_build_script = read("scripts", "build-python-runtime.sh")
key_mapper_src = read("src", "key_mapper.py")
main_src = read("src", "main.py")
window_switcher_src = read("src", "window_switcher.py")
runtime_src = read("src", "runtime.py")
readme = read("README.md")
changelog = read("CHANGELOG.md")

config = json.loads(read("config", "user.json"))
hotspots = json.loads(read("assets", "controller", "hotspots.json"))

# Imported, not grepped: comparing the actual bit table and the actual
# resolved threshold is the whole point. That means this script needs the
# runtime's dependencies -- run it from the project venv.
try:
    from src.config_loader import BUILT_IN_ACTIONS, GESTURE_SLOTS  # noqa: E402
    from src.constants import BUTTON_NAMES_BY_MODE, DEFAULT_LONG_PRESS_THRESHOLD  # noqa: E402
    from src.side_button_reader import _LEFT_BUTTON_BITS, _RIGHT_BUTTON_BITS  # noqa: E402
except ModuleNotFoundError as missing:
    raise SystemExit(
        f"verify-native-ui-contract needs the runtime's dependencies ({missing.name} is missing).\n"
        "Run it from the project venv:\n"
        "  .venv/bin/pip install -r requirements.txt\n"
        "  .venv/bin/python scripts/verify-native-ui-contract.py"
    ) from None


def button_specs(side: str) -> list[tuple[str, str, str]]:
    """MappingConfigReader.buttonSpecs, as data."""
    body = mapping_config.split("if side == .right {")[1]
    right, rest = body.split("}", 1)
    raw = right if side == "right" else rest.split("return [")[-1].split("]")[0]
    return re.findall(r'\("([^"]+)", "([^"]+)", "([^"]+)"\)', raw)


SPECS = {side: button_specs(side) for side in ("left", "right")}

# --------------------------------------------------------------------------
# 1. Which buttons a side has.
#    Authority: src/constants.py BUTTON_NAMES_BY_MODE.
#    Restated by: the HID bit tables, MappingConfig.buttonSpecs, hotspots.json,
#    config/user.json.
# --------------------------------------------------------------------------
for side, mode in (("left", "single_left"), ("right", "single_right")):
    authority = set(BUTTON_NAMES_BY_MODE[mode].values())
    bits = set(_LEFT_BUTTON_BITS if side == "left" else _RIGHT_BUTTON_BITS)
    swift = {button for button, _, _ in SPECS[side]}
    configured = set(config["profiles"][mode]["mappings"]["buttons"])
    hotspot_keys = set(hotspots["points"][side])
    swift_hotspots = {hotspot for _, _, hotspot in SPECS[side]}

    check(bits == authority, f"[{side}] side_button_reader bit table != constants", f"{bits ^ authority}")
    check(swift == authority, f"[{side}] MappingConfig.buttonSpecs != constants", f"{swift ^ authority}")
    check(configured == authority, f"[{side}] config/user.json buttons != constants", f"{configured ^ authority}")
    check(hotspot_keys == swift_hotspots, f"[{side}] hotspots.json keys != buttonSpecs", f"{hotspot_keys ^ swift_hotspots}")
    check(len(hotspot_keys) == 11, f"[{side}] expected 11 hotspots, found {len(hotspot_keys)}")

# --------------------------------------------------------------------------
# 2. Where a button physically is, and how the two sides mirror.
#    Authority: assets/controller/hotspots.json.
#
#    The left controller's rail was drawn mirrored on x alone, which put SR on
#    the upper rail button; on a left Joy-Con the upper one is SL. And the left
#    d-pad's X/B were swapped against the HID bit table, so pressing Up fired
#    the mapping the UI had drawn at Down.
# --------------------------------------------------------------------------
LEFT, RIGHT = hotspots["points"]["left"], hotspots["points"]["right"]
check(LEFT["SL"]["y"] < LEFT["SR"]["y"], "left rail: SL must be drawn above SR")
check(RIGHT["SR"]["y"] < RIGHT["SL"]["y"], "right rail: SR must be drawn above SL")

DPAD = {"X": "↑", "A": "→", "B": "↓", "Y": "←"}
for button, glyph in DPAD.items():
    check((button, glyph, glyph) in SPECS["left"],
          f"left {button} must be drawn as {glyph}",
          f"{[spec for spec in SPECS['left'] if spec[0] == button]}")
check(LEFT["↑"]["y"] == min(LEFT[g]["y"] for g in DPAD.values()), "left ↑ must be the topmost d-pad hotspot")
check(LEFT["↓"]["y"] == max(LEFT[g]["y"] for g in DPAD.values()), "left ↓ must be the lowest d-pad hotspot")
check(LEFT["←"]["x"] < LEFT["→"]["x"], "left ← must be left of →")
check(RIGHT["X"]["y"] == min(RIGHT[b]["y"] for b in DPAD), "right X must be the topmost face hotspot")
check(RIGHT["B"]["y"] == max(RIGHT[b]["y"] for b in DPAD), "right B must be the lowest face hotspot")
check(RIGHT["Y"]["x"] < RIGHT["A"]["x"], "right Y must be left of A")

# Same physical position, same mapping. The rails cross: the left controller's
# lower rail button is SR, the right controller's lower one is SL.
MIRROR = [("X", "X"), ("Y", "Y"), ("A", "A"), ("B", "B"), ("L", "R"), ("ZL", "ZR"),
          ("Minus", "Plus"), ("Capture", "Home"), ("LStick", "RStick"),
          ("SL", "SR"), ("SR", "SL")]
left_buttons = config["profiles"]["single_left"]["mappings"]["buttons"]
right_buttons = config["profiles"]["single_right"]["mappings"]["buttons"]
for left_name, right_name in MIRROR:
    check(left_buttons[left_name] == right_buttons[right_name],
          f"mirror broken: left {left_name} != right {right_name}",
          f"{left_buttons[left_name]} vs {right_buttons[right_name]}")

# --------------------------------------------------------------------------
# 3. The default mappings.
#    Authority: config/user.json (and the copy of it bundled as DefaultConfig).
#    Restated by: the 连接 page's preview order and the onboarding button test.
# --------------------------------------------------------------------------
check('cp "$ROOT_DIR/config/user.json" "$RESOURCE_DIR/DefaultConfig.json"' in build_script,
      "恢复推荐 reads DefaultConfig.json from the bundle; the build must put it there")
check('forResource: "DefaultConfig"' in app_model,
      "恢复推荐 must read the shipped config, not a second table written in Swift")

for side in ("left", "right"):
    listed = re.search(rf"\.{side}: \[([^\]]*)\]", connection_view)
    buttons = re.findall(r'"([^"]+)"', listed.group(1)) if listed else []
    mode = f"single_{side}"
    check(buttons and set(buttons) <= set(config["profiles"][mode]["mappings"]["buttons"]),
          f"ConnectionView.previewOrder[{side}] names a button that does not exist", f"{buttons}")

check("workflowChecks: [OnboardingCheck] { state.onboardingChecks }" in onboarding_view,
      "the onboarding button test must read the installed mappings, not its own table",
      "it once hardcoded ZR=fn / +=⌘V and went on teaching that after a remap")
for literal in ('"fn", "按一下"', '"⌘V"', '"⌥A"', '"↩", "按一下"'):
    forbid(onboarding_view, literal,
           f"OnboardingView hardcodes the shortcut {literal} again")

# --------------------------------------------------------------------------
# 4. What action types exist.
#    Authority: config_loader (BUILT_IN_ACTIONS + GESTURE_SLOTS + passthrough).
#    Restated by: key_mapper's dispatch, MappingActionDraft, ActionCatalog.
# --------------------------------------------------------------------------
ACTIONS = set(BUILT_IN_ACTIONS) | set(GESTURE_SLOTS) | {"passthrough", "disabled"}
dispatched = set(re.findall(r'action == "(\w+)"', key_mapper_src))
catalogued = set(re.findall(r'"(\w+)": "', action_catalog))
drafted = set(re.findall(r'case "(\w+)": return \.', mapping_editor))

check(ACTIONS <= dispatched | {"disabled"}, "key_mapper does not dispatch every valid action",
      f"undispatched: {sorted(ACTIONS - dispatched - {'disabled'})}")
check(ACTIONS <= catalogued | set(GESTURE_SLOTS) | {"passthrough"},
      "ActionCatalog has no name for every valid action",
      f"unnamed: {sorted(ACTIONS - catalogued - set(GESTURE_SLOTS) - {'passthrough'})}")
check(set(re.findall(r'"([a-z_]+)"', re.search(r"editableActions: \[String\] = \[([^\]]*)\]", action_catalog).group(1))) <= ACTIONS,
      "the editor's ⋯ menu offers an action config_loader would reject")

# A second, stale list of action types is exactly how this drifted before:
# constants.VALID_ACTIONS still named tap/hold/auto/combination/sequence and
# had never heard of passthrough or focus_input.
forbid(read("src", "constants.py"), "VALID_ACTIONS",
       "constants.py carries a second list of action types again")

# The CLI summary is the only surface outside the app that describes mappings,
# and it is what the runtime build runs as its smoke test. It once printed "?"
# for fifteen of the sixteen shipped mappings.
for shape in ('if action == "passthrough"', 'if action in GESTURE_SLOTS'):
    require(main_src, shape, f"--list-controls no longer understands {shape}")
_summarised = set(re.findall(r'"(\w+)": "', main_src.split("_BUILT_IN_SUMMARIES = {")[1].split("}")[0]))
check(set(BUILT_IN_ACTIONS) <= _summarised, "--list-controls cannot describe every built-in",
      f"undescribed: {sorted(set(BUILT_IN_ACTIONS) - _summarised)}")

# --------------------------------------------------------------------------
# 5. What an action is called, in Chinese.
#    Authority: ActionCatalog. This row had no single source at all.
# --------------------------------------------------------------------------
check((NATIVE / "ActionCatalog.swift").exists(), "ActionCatalog.swift is gone")
for view, what in ((mapping_config, "MappingConfigReader"),
                   (mapping_editor, "MappingActionDraft"),
                   (connection_view, "ConnectionView")):
    check("ActionCatalog" in view, f"{what} names actions without going through ActionCatalog")

# Every name the catalog can show must also be explainable, or the 连接 page
# silently falls back to "常用操作".
names = dict(re.findall(r'"([a-z_]+)": "([^"]+)"', action_catalog.split("static let names")[1].split("]")[0]))
meanings = action_catalog.split("actionMeanings")[1]
for action, label in names.items():
    if action == "disabled":
        continue
    check(f'"{action}"' in meanings, f"ActionCatalog can show 「{label}」 but cannot explain it")

# --------------------------------------------------------------------------
# 6. Thresholds and timing.
#    Authority: config/user.json + the system keyboard settings.
#
#    "长按" used to be 250ms on a built-in and 350ms on a gesture split, while
#    the UI called both 长按 -- and the number itself existed in six places.
# --------------------------------------------------------------------------
threshold = config.get("long_press_threshold")
check(threshold is not None, "config/user.json must declare long_press_threshold")
check(threshold == DEFAULT_LONG_PRESS_THRESHOLD,
      "the shipped long_press_threshold disagrees with the compiled-in fallback",
      f"config={threshold} constants={DEFAULT_LONG_PRESS_THRESHOLD}")
per_button = [name for profile in config["profiles"].values()
              for name, mapping in profile["mappings"]["buttons"].items() if "threshold" in mapping]
check(not per_button, "the shipped config stamps a per-button threshold again",
      f"{per_button} -- absent means 'use long_press_threshold', which is the point")
forbid(app_model, '"threshold": 0.35',
       "the mapping editor writes its own copy of the long-press threshold again")
check("duration >= longPressThreshold" in app_model,
      "the onboarding button test hardcodes a long-press duration again")
check("long_press_threshold" in app_model,
      "AppState must read the threshold from the config the runtime reads")
# Checked by construction rather than by reading the source: what matters is
# that a built-in and a gesture split resolve to the SAME number, which is the
# thing that was wrong (0.25 vs 0.35 under one word, "长按").
_mapper = __import__("src.key_mapper", fromlist=["KeyMapper"]).KeyMapper(config, mode="single_right")
_gesture = config["profiles"]["single_right"]["mappings"]["buttons"]["A"]
check(_mapper._long_threshold == threshold,
      "the runtime's long-press threshold is not the one in the config",
      f"KeyMapper={_mapper._long_threshold} config={threshold}")
check(_gesture.get("threshold", _mapper._long_threshold) == _mapper._long_threshold,
      "a gesture split and a built-in resolve to different long-press thresholds",
      "both are called 长按 in the UI, so both must be the same duration")

# Key repeat belongs to System Settings, so a per-key value would be ignored.
require(read("src", "config_loader.py"), '"repeat" in mapping', "per-key repeat is still rejected")

# --------------------------------------------------------------------------
# 7. Bundle id, data directories, version.
#    Authority: the build script (which writes Info.plist).
# --------------------------------------------------------------------------
# The data and IPC paths live in Info.plist and nowhere else -- the build
# script writes them, the app reads them back by key. So what has to agree is
# the key names: a rename on one side leaves the app silently falling back to
# a different directory from the one the installer and the runtime use.
app_model_paths = read("macos", "JoyHarnessNative", "AppModel.swift")
for value in ("com.yongboxia.joyharness", "~/Library/Application Support/JoyHarness"):
    check(value in build_script, f"the build script no longer sets {value}")
for key in ("JoyHarnessRuntimePath", "JoyHarnessIPCPath"):
    check(key in build_script and key in app_model_paths,
          f"the Info.plist key {key} is not written and read by the same name",
          "the app would fall back to a different directory than the installer uses")

version = re.search(r'VERSION="\$\{JOYHARNESS_VERSION:-([^}]+)\}"', build_script).group(1)
newest = re.search(r"## \[([\d.]+)\]", changelog).group(1)
check(version == newest, "the version the build stamps is not the newest CHANGELOG version",
      f"build={version} CHANGELOG={newest}")
# The README deliberately carries NO version number. It links to
# releases/latest instead, which is right by construction -- a number written
# here would be one more copy to remember on every release, and forgetting it
# is exactly how the 关于 page ended up claiming 0.2.0 on a 0.1.0 tree.
check(not re.search(r"v\d+\.\d+", readme),
      "README hardcodes a version again; link to releases/latest instead",
      f"{re.findall(chr(114)+'v.d+.d+', readme)}")
check("releases/latest" in readme, "README no longer points at the latest release")
check(re.search(r'__version__ = "([\d.]+)"', read("src", "constants.py")).group(1) == newest,
      "--version prints a different number than the app shows")
forbid(about_view, '?? "0.2.0"', "AboutView invents a fallback version number again")

# --------------------------------------------------------------------------
# 8. Affordances that must not quietly disappear.
# --------------------------------------------------------------------------
for symbol in ('return "link"', 'return "keyboard"', 'return "info.circle"'):
    require(app_model, symbol, f"sidebar symbol {symbol}")
require(root_view, ".contentShape(Rectangle())", "full-row sidebar hit target")
require(root_view, '.accessibilityIdentifier("sidebar-', "stable sidebar accessibility identifiers")
require(root_view, ".accessibilityValue(state.selectedPage == page", "sidebar selected accessibility state")
require(mapping_view, "Button {", "mapping cards use semantic buttons")
require(mapping_view, ".contentShape(RoundedRectangle", "full-card mapping hit target")
require(mapping_view, '.accessibilityIdentifier("mapping-card-', "stable mapping-card accessibility identifiers")
require(mapping_view, "Canvas {", "hotspot connector canvas")
require(mapping_view, "ControllerHotspotReader.load()", "calibrated hotspot input")
require(mapping_view, "static func height(for card: MappingCardModel)", "content-sized mapping cards")
require(mapping_view, "min((usableHeight - stacked) / CGFloat(columnCards.count - 1), LayoutItem.gap)",
        "both columns cap their card gap at the same LayoutItem.gap")
require(design, ".contentShape(Rectangle())", "custom button hit targets")
require(design, "struct ConnectionStatusBadge", "connection status badge")
require(design, "struct RefreshButton", "refresh button feedback")
require(design, "struct IconButtonStyle", "icon button hover and press feedback")
require(connection_view, "ConnectionStatusBadge(availability: state.availability)", "connection page status badge")
require(connection_view, "state.refreshStatusWithFeedback()", "connection page refresh feedback")
require(app_model, "func refreshStatusWithFeedback()", "status refresh feedback state")
require(app_model, "enum AppAppearance", "three-state appearance model")
require(app_model, "SMAppService.mainApp.register()", "native login-item registration")
require(app_model, "SMAppService.mainApp.unregister()", "native login-item removal")
require(app_model, "UserDefaults.standard.set(value.rawValue", "appearance persistence")
require(about_view, '.accessibilityIdentifier("appearance-picker")', "appearance picker accessibility contract")
require(about_view, '.accessibilityIdentifier("launch-at-login-toggle")', "login-item toggle accessibility contract")
require(about_view, '.accessibilityIdentifier("export-diagnostics")', "diagnostic export action")
require(about_view, "辅助功能授权", "accessibility grant row")
require(about_view, "重启服务", "service restart action")
require(root_view, "state.isShowingOnboarding", "first-run onboarding presentation")
require(onboarding_view, "private var pendingCheck", "one-at-a-time shortcut onboarding")
require(onboarding_view, "state.leftController.connected || state.rightController.connected",
        "either controller satisfies onboarding")
# Two boundaries the walkthrough has to state, asserted by meaning rather
# than by one literal sentence -- the wording is allowed to improve.
#
# 1. Speech recognition is not part of this product.
check(any(t in onboarding_view for t in ("语音识别由你", "不含这一段", "由你自己选")),
      "the walkthrough no longer says speech recognition is someone else's job")
# 2. fn is the voice-input trigger, and it only does something once the
#    user's own tool is listening for it. Without this, a first press of ZR
#    does nothing visible and the product looks broken -- which is exactly
#    what it looks like when it is working correctly.
check("fn" in onboarding_view and "启动快捷键设成" in onboarding_view,
      "the walkthrough no longer tells the user to bind fn in their voice tool")
# 3. A brand may be recommended, never required.
check("换成别的也可以" in onboarding_view or "都行" in onboarding_view,
      "the walkthrough presents a specific voice tool as mandatory")
require(app_model, "processOnboardingInputEvents", "runtime input event monitoring")
require(mapping_editor, "ShortcutRecorderControl", "keyboard shortcut recording control")
require(mapping_editor, "Command+V", "manual shortcut entry")
require(mapping_config, 'gesture: nil', "single-action buttons carry no gesture label")
require(runtime_manager, 'environment["JOYHARNESS_INPUT_BACKEND"] = "native"', "native-only production input backend")
require(runtime_manager, '"--native-client"', "headless bundled runtime mode")
require(status_bar, "MenuBarIconRenderer.image", "custom menu-bar icon")
require(status_bar, "button.contentTintColor = nil", "system-controlled template tint")
require(menu_bar_icon, "image.isTemplate = true", "native template image")
require(menu_bar_icon, "case paused", "paused menu-bar badge")
require(menu_bar_icon, "case warning", "warning menu-bar badge")

forbid(about_view, '.disabled(state.buildFlavor == "preview")', "Preview still disables the login-item control")
all_swift = "\n".join(path.read_text(encoding="utf-8") for path in NATIVE.glob("*.swift"))
forbid(all_swift, "onTapGesture", "Native client still contains gesture-only click targets")
forbid(all_swift, "inputMonitoring", "Native client still requires Input Monitoring")
check(not (NATIVE / "PermissionsView.swift").exists(),
      "PermissionsView is back; authorization belongs in AboutView")
forbid(about_view, "后台服务", "关于 exposes the runtime process; users get one 重启服务 action instead")

# --------------------------------------------------------------------------
# 9. Fixes whose failure mode is to come back quietly.
# --------------------------------------------------------------------------
# The status row on the 连接 page must reflect every reason a press can do
# nothing, not just the user's own pause.
check("state.availability" in connection_view.split("按键响应")[1].split("recoveryCard")[0],
      "the 按键响应 row reads only `paused` again",
      "it said 按键正在发出快捷键 on the same screen as the 还需要完成系统授权 banner")

# The menu bar must not re-derive connection wording; a sleeping controller
# reads 未连接 the moment it does.
check("status.statusText" in status_bar,
      "StatusBarController derives its own connection text again, losing 已休眠")

# .notFound is what a never-registered login item reads as -- the state every
# new install starts in.
check("case .notRegistered, .notFound:" in app_model,
      "the login-item row treats .notFound as a failure again",
      "it told every new user to move an app that was already in /Applications")
forbid(app_model, "请将 App 放入", "the unactionable login-item instruction is back")

# Dismissing the walkthrough has to record something, or it reopens at every
# launch -- and its last step cannot be reached without a grant and a
# controller, so "finish it to stop it" is not a way out.
check("func dismissOnboarding(markCompleted: Bool = true)" in app_model,
      "稍后设置 stops recording that the walkthrough was shown")

# The runtime numbers its input events from one again after a restart.
check("highest < latestInputSequence" in app_model,
      "the onboarding button test cannot recover from a runtime restart")

# Rollback means the file went back. Telling the runtime is best effort.
check("try? await runtimeClient.reloadConfig()" in config_store,
      "ConfigStore counts a failed notify as a failed rollback again",
      "that reported 自动恢复失败 on top of a rollback that had succeeded")
check("completion: @escaping (String?) -> Void" in app_model,
      "a failed mapping save no longer reports back to the sheet",
      "the root alert cannot appear over an open sheet, so it looked like nothing happened")

# window_switch promises a second level the shipped runtime cannot deliver.
check("set_tk_root" not in runtime_src,
      "something calls set_tk_root now; re-check whether window_switch's 长按 works")
if "--exclude-module tkinter" in runtime_build_script and "set_tk_root" not in runtime_src:
    check('"window_switch"' not in re.search(r"editableActions: \[String\] = \[([^\]]*)\]", action_catalog).group(1),
          "聚焦窗口 is offered in the editor again, but its 长按 still cannot happen")
    check('value: "选择窗口"' not in mapping_config,
          "the card promises 长按 → 选择窗口 again for a long press that does nothing")

# Colour literals live in one file. Six in DesignSystem (four status colours
# plus the two key-cap tones); anywhere else means a second palette starting.
_literals = {path.name: len(re.findall(r"Color\(red:", path.read_text(encoding="utf-8")))
             for path in NATIVE.glob("*.swift")}
_stray = {name: count for name, count in _literals.items()
          if count and name != "DesignSystem.swift"}
check(not _stray, "colour literals outside DesignSystem.swift", f"{_stray}")

# A DMG is installed on real machines, so it must never be ad-hoc signed by
# accident -- that re-books the Accessibility grant on every install.
dmg_script = read("scripts", "build-dmg-installer.sh")
check("JOYHARNESS_CODESIGN_IDENTITY" in dmg_script,
      "the DMG can be built unsigned again",
      "an ad-hoc signature changes every build, so macOS forgets the Accessibility grant each install")

# A write-only config field is a field that will be wrong and never noticed.
check("set_known_apps" not in window_switcher_src and "known_apps" not in json.dumps(config),
      "known_apps is back; nothing reads it, and it shipped the author's own app list")

# PyObjC's three modules are imported together, so they must be required
# together -- ApplicationServices missing silently disabled the whole fast path.
runtime_requirements = read("requirements-macos-runtime.txt")
for package in ("pyobjc-framework-Cocoa", "pyobjc-framework-Quartz", "pyobjc-framework-ApplicationServices"):
    check(package in runtime_requirements, f"the bundled runtime no longer requires {package}",
          "window_switcher imports all three in one try block; one missing disables the PyObjC path")

# The runtime's "already running" exit code is restated in Swift so the app can
# tell a duplicate launch from a crash. A drift is silent and user-visible: the
# app would tell the user to restart a service that is already running.
from src import process_guard  # noqa: E402

runtime_manager_src = read("macos", "JoyHarnessNative", "RuntimeManager.swift")
check(f"runtimeAlreadyRunningExitCode: Int32 = {process_guard.EXIT_ALREADY_RUNNING}"
      in runtime_manager_src,
      "Swift and Python disagree about the 'already running' exit code",
      f"src/process_guard.py says {process_guard.EXIT_ALREADY_RUNNING}; "
      "RuntimeManager.swift must say the same")

# Every hidapi call goes through hid_access, which serialises them. Calling the
# library directly puts a second thread inside its C code with the GIL
# released, which is what aborted the runtime out of malloc on 2026-09-14.
for module in ("side_button_reader", "keep_alive", "runtime", "joycon_reader"):
    source = read("src", f"{module}.py")
    check("import hid\n" not in source and "hid.enumerate" not in source
          and "hid.device()" not in source,
          f"src/{module}.py calls hidapi directly instead of through hid_access",
          "unsynchronised hidapi access corrupts its global state; see src/hid_access.py")

# The status scratch file must be per-process. A shared name is what produced
# 823 FileNotFoundError in the 2026-09-14 log when two runtimes overlapped.
check("getpid()" in read("src", "runtime_ipc.py"),
      "the status scratch file is no longer per-process",
      "two runtimes sharing one .tmp name lose status writes to each other")

# Idle sleep ships on. The minute count is stated twice -- in the default
# config, and in Swift as the value the toggle writes when it is switched back
# on -- so a drift would make turning the setting off and on again change how
# long the controller waits.
app_model_src = read("macos", "JoyHarnessNative", "AppModel.swift")
default_idle_minutes = config.get("idle_sleep_minutes")
check(default_idle_minutes == 10,
      f"the default config no longer sleeps an idle controller (idle_sleep_minutes={default_idle_minutes})",
      "it ships enabled so an unattended controller does not stay awake overnight")
check(f"defaultIdleSleepMinutes: Double = {default_idle_minutes}" in app_model_src,
      "Swift and the default config disagree about the idle-sleep delay",
      f"config/user.json says {default_idle_minutes}; AppModel.defaultIdleSleepMinutes must match")

# Sparkle compares CFBundleVersion to decide whether a release is an upgrade.
# A constant there is the quiet failure mode for auto-update: the feed parses,
# the check runs on schedule, and no update is ever offered to anyone.
check("<key>CFBundleVersion</key>\n  <string>$VERSION</string>" in build_script,
      "CFBundleVersion is not the release version",
      "Sparkle compares it to decide what is newer; a fixed value offers nothing, silently")

# An update the app cannot verify is an update anyone could have written. Both
# halves have to be present: a feed with no key, or a key with no feed, and
# Sparkle either checks nothing or trusts anything.
for key in ("SUFeedURL", "SUPublicEDKey"):
    check(key in build_script, f"the Info.plist no longer carries {key}",
          "without both, updates are either never found or never verified")

# Presence was the whole check, which left the feed address the one string in
# the bundle that nothing read. It is compiled into every copy we ship and
# cannot be corrected for one already installed, so a typo here publishes a
# build whose updater talks to nothing -- every check green, every install
# frozen on the version it arrived with. The feed and the packages it
# announces are published together by release.yml; change one address without
# the other and the feed parses while every download in it 404s. So read the
# value, and check it against the workflow that does the publishing.
release_workflow = read(".github", "workflows", "release.yml")
feed_match = re.search(r"<key>SUFeedURL</key>\s*\n\s*<string>([^<]*)</string>", build_script)
check(feed_match is not None,
      "SUFeedURL is no longer a literal string in the Info.plist",
      "its value cannot be checked, and a feed that resolves to nothing fails silently")
if feed_match:
    feed_url = feed_match.group(1)
    check(feed_url.startswith("https://"),
          f"SUFeedURL is not HTTPS ({feed_url})",
          "Sparkle refuses a plaintext feed, so no update is ever offered")
    feed_prefix = feed_url.rsplit("/", 1)[0] + "/"
    check(feed_prefix in release_workflow,
          f"SUFeedURL points at {feed_prefix}, which release.yml never publishes to",
          "the feed and the packages it announces have to land on the same host")

# Upgrades leave the previous version's runtime running: replacing the app
# bundle never runs applicationWillTerminate, and a runtime from before the
# single-instance lock existed never takes that lock, so no later runtime can
# see it. Only the app can, and only by looking at the process list -- so the
# start path has to do that before launching its own.
check("terminateRuntimesNotOwnedByUs(configPath: configURL.path)" in runtime_manager_src,
      "the app no longer clears leftover runtimes before starting its own",
      "an old version's runtime keeps the controller and keeps rewriting status.json")

# A status file that is fresh but unparseable is not a stopped service.
# Reporting it as one sent the user to restart a runtime that was alive.
check("hasReportedUnreadableStatus = true" in app_model_paths,
      "an unreadable status.json reads as 'service not running' again",
      "that sends the user to the restart button for a service that is running")

# A runtime that dies during startup has to leave a reason behind.
main_src = read("src", "main.py")
check("record_lifecycle()" in main_src,
      "the runtime no longer records its pid, parent and exit",
      "a killed startup then leaves one log line and no way to tell why it stopped")

# --------------------------------------------------------------------------
if FAILURES:
    print(f"Native UI contract verification FAILED ({len(FAILURES)} of {CHECKS} checks):")
    for failure in FAILURES:
        print(f"  - {failure}")
    raise SystemExit(1)

print(f"Native UI contract verification passed ({CHECKS} checks).")
