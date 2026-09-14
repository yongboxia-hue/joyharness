#!/bin/bash
# Put the machine back on a checkpointed build, without rebuilding anything.
#
#   bash scripts/rollback-to-checkpoint.sh                     # newest checkpoint
#   bash scripts/rollback-to-checkpoint.sh checkpoint-2026-09-12
#
# Each checkpoint keeps the signed .app and the config that was live at the
# time, so this restores behaviour even if the source tree has moved on. The
# git tag of the same name holds the matching source.
set -euo pipefail

BACKUP_ROOT="$HOME/Library/Application Support/JoyHarness/Install Backups"
CONFIG="$HOME/Library/Application Support/JoyHarness/config/user.json"
TARGET="/Applications/JoyHarness.app"

NAME="${1:-}"
if [ -z "$NAME" ]; then
  NAME="$(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort | tail -1)"
fi
SOURCE="$BACKUP_ROOT/$NAME"

if [ ! -d "$SOURCE/JoyHarness.app" ]; then
  echo "No checkpoint named '$NAME'. Available:" >&2
  ls -1 "$BACKUP_ROOT" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

echo "Rolling back to: $NAME"

osascript -e 'tell application "JoyHarness" to quit' 2>/dev/null || true
sleep 1
pkill -9 -f "JoyHarness.app/Contents/MacOS/JoyHarness" 2>/dev/null || true
pkill -9 -f JoyHarnessRuntime 2>/dev/null || true
sleep 1

rm -rf "$TARGET"
ditto "$SOURCE/JoyHarness.app" "$TARGET"
codesign --verify --strict "$TARGET"

# The checkpoint's config goes back too: a newer config_version installed
# since then would otherwise stay in place and the old build would run
# mappings it was never tested against.
if [ -f "$SOURCE/user.json" ]; then
  mkdir -p "$(dirname "$CONFIG")"
  [ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.before-rollback"
  cp "$SOURCE/user.json" "$CONFIG"
fi

open -a "$TARGET"
sleep 6
pgrep -f "JoyHarness.app/Contents/MacOS/JoyHarness" >/dev/null \
  || { echo "App did not start" >&2; exit 1; }

echo "Rolled back and running. Source for this build: git checkout $NAME"
