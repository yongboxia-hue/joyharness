"""Joy-Con hardware constants.

The set of valid action types is NOT here: config_loader owns it
(BUILT_IN_ACTIONS + GESTURE_SLOTS + "passthrough"), because that is the module
that validates against it. A second tuple used to sit in this file and had
drifted badly -- it still listed tap/hold/auto/combination/sequence, none of
which key_mapper dispatches any more, and was missing passthrough and
focus_input, which is what almost every shipped mapping actually uses.

NOTE: Button and axis indices below are based on SDL2's Switch controller
mapping and are a leftover from the pre-raw-HID input path
(see joycon_reader.py); the actual input path (side_button_reader.py)
reads raw HID reports directly and doesn't use these indices at all.

There are two independent profiles: single_right and single_left. Each
controller always runs its own -- by product decision there's no separate
"dual" profile that changes a side's mappings depending on whether the
other controller happens to be connected too. runtime.py always starts
both readers, each against its own KeyMapper, whether or not the other
controller is actually plugged in.
"""

# === Right Joy-Con Button Indices (calibrated 2026-04-09) ===
# Face buttons
BTN_X = 0       # X (上位)
BTN_A = 1       # A (右位)
BTN_Y = 2       # Y (左位)
BTN_B = 3       # B (下位)

# System / Home
BTN_HOME = 5    # Home (圆形)
BTN_PLUS = 6    # + 按钮
BTN_RSTICK = 7  # 摇杆按下

# Shoulder / trigger
BTN_SL = 9      # SL (侧边左)
BTN_R = 16      # R 肩键
BTN_SR = 10     # SR (侧边右)
BTN_ZR = 18     # ZR 扳机

# === Left Joy-Con Button Indices ===
BTN_L_Y = 0       # Y
BTN_L_B = 1       # B
BTN_L_X = 2       # X
BTN_L_A = 3       # A
BTN_L_MINUS = 4   # - 按钮
BTN_L_CAPTURE = 5 # Capture 按钮
BTN_L_LSTICK = 6  # 左摇杆按下
BTN_L_SL = 9      # SL
BTN_L_SR = 10     # SR
BTN_L_L = 16      # L 肩键
BTN_L_ZL = 18     # ZL 扳机

# === Axis Indices (calibrated) ===
AXIS_RSTICK_Y = 0   # 垂直 (上=负, 下=正)
AXIS_RSTICK_X = 1   # 水平 (左=负, 右=正)

# === Default Values ===
DEFAULT_DEADZONE = 0.2
DEFAULT_DOUBLE_TAP_TIMEOUT = 0.35
# How long a button must be held before it counts as a long press. This is the
# compiled-in fallback for every path that splits a press by duration --
# short_long/double_tap/multi_trigger and the built-ins (app_switch_mode,
# window_switch) alike. They used to read two different numbers, so "长按" was
# 250ms on one button and 350ms on the next while the UI called both 长按.
# config/user.json's top-level `long_press_threshold` overrides it.
DEFAULT_LONG_PRESS_THRESHOLD = 0.35
DIRECTION_THRESHOLD = 0.5
POLL_INTERVAL = 0.01       # 100Hz polling
SNAPBACK_FRAMES = 2        # Frames required at center before registering release

# === Right Joy-Con Button Name Lookup ===
BUTTON_NAMES: dict[int, str] = {
    BTN_A: "A",
    BTN_B: "B",
    BTN_X: "X",
    BTN_Y: "Y",
    BTN_R: "R",
    BTN_ZR: "ZR",
    BTN_PLUS: "Plus",
    BTN_RSTICK: "RStick",
    BTN_HOME: "Home",
    BTN_SL: "SL",
    BTN_SR: "SR",
}

# Reverse lookup: name → index
BUTTON_INDICES: dict[str, int] = {v: k for k, v in BUTTON_NAMES.items()}

# === Left Joy-Con Button Name Lookup ===
BUTTON_NAMES_LEFT: dict[int, str] = {
    BTN_L_A: "A",
    BTN_L_B: "B",
    BTN_L_X: "X",
    BTN_L_Y: "Y",
    BTN_L_L: "L",
    BTN_L_ZL: "ZL",
    BTN_L_MINUS: "Minus",
    BTN_L_CAPTURE: "Capture",
    BTN_L_LSTICK: "LStick",
    BTN_L_SL: "SL",
    BTN_L_SR: "SR",
}
BUTTON_INDICES_LEFT: dict[str, int] = {v: k for k, v in BUTTON_NAMES_LEFT.items()}

# === Mode-based lookup tables ===
BUTTON_NAMES_BY_MODE: dict[str, dict[int, str]] = {
    "single_right": BUTTON_NAMES,
    "single_left": BUTTON_NAMES_LEFT,
}

BUTTON_INDICES_BY_MODE: dict[str, dict[str, int]] = {
    "single_right": BUTTON_INDICES,
    "single_left": BUTTON_INDICES_LEFT,
}

# Purely descriptive labels for JoyHarnessRuntime.connection_mode (a status
# string -- "both connected", "just the left one", etc.) -- not a profile
# selector. Each controller always runs its own single_right/single_left
# mappings regardless of what this says.
MODE_LABELS: dict[str, str] = {
    "single_right": "右手柄",
    "single_left": "左手柄",
    "dual": "左右手柄",
    "none": "未连接",
}


def get_button_names(mode: str = "single_right") -> dict[int, str]:
    """Get button name lookup table for a connection mode."""
    return BUTTON_NAMES_BY_MODE.get(mode, BUTTON_NAMES)


def get_button_indices(mode: str = "single_right") -> dict[str, int]:
    """Get button index lookup table for a connection mode."""
    return BUTTON_INDICES_BY_MODE.get(mode, BUTTON_INDICES)


# === Stick Direction Names ===
STICK_DIRECTIONS = ("up", "down", "left", "right", "up-left", "up-right", "down-left", "down-right")

__version__ = "0.1.5"
