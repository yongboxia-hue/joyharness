#!/bin/bash
# Install the production build over /Applications/JoyHarness.app and restart it.
#
# `osascript -e 'quit'` is not enough on its own: the menu-bar app can stay
# alive through it, and `open -a` then just re-activates the process that is
# already running -- from the bundle that was deleted out from under it -- so
# the new build silently never runs. Kill by executable path, wait, then open.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT_DIR/build/macos-swiftui/JoyHarness.app}"
TARGET="/Applications/JoyHarness.app"

[ -d "$SOURCE" ] || { echo "No build at $SOURCE" >&2; exit 1; }

osascript -e 'tell application "JoyHarness" to quit' 2>/dev/null || true
sleep 1
pkill -9 -f "JoyHarness.app/Contents/MacOS/JoyHarness" 2>/dev/null || true
pkill -9 -f JoyHarnessRuntime 2>/dev/null || true
sleep 1

rm -rf "$TARGET"
ditto "$SOURCE" "$TARGET"
codesign --verify --strict "$TARGET"

open -a "$TARGET"
sleep 6
pgrep -f "JoyHarness.app/Contents/MacOS/JoyHarness" >/dev/null \
  || { echo "App did not start" >&2; exit 1; }
echo "Installed and running: $TARGET"
codesign -dv "$TARGET" 2>&1 | grep -E "^Authority|TeamIdentifier" || true
