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

"$WORK_DIR/verify-native-hit-targets" "$PID"
