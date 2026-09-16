#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/macos-swiftui/JoyHarness Preview.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/JoyHarness"
PID="${JOYHARNESS_PREVIEW_PID:-$(pgrep -f "$EXECUTABLE" | head -1)}"

if [ -z "$PID" ]; then
  echo "JoyHarness Preview must be running before hit-target verification." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joyharness-hit-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

clang \
  -framework ApplicationServices \
  -framework CoreFoundation \
  -framework CoreGraphics \
  "$ROOT_DIR/scripts/verify-native-hit-targets.c" \
  -o "$WORK_DIR/verify-native-hit-targets"

# The checker synthesises real clicks, and a click on a background app's window
# is spent activating that app instead of reaching what it landed on -- so the
# card-opens-the-editor assertion passed or failed depending on which window
# happened to be in front. Bring the app forward first and let it settle.
open -a "$APP_PATH"
# A cold launch is still laying out when a one-second wait ends, and the
# first synthetic click then lands on a window that is not ready for it.
sleep 3

"$WORK_DIR/verify-native-hit-targets" "$PID"
