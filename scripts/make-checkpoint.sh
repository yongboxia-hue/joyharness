#!/bin/bash
# Snapshot the currently installed app + config, and tag the source to match.
#
#   bash scripts/make-checkpoint.sh checkpoint-2026-09-12 "why this point matters"
set -euo pipefail

NAME="${1:?usage: make-checkpoint.sh <name> [message]}"
MESSAGE="${2:-Checkpoint $NAME}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$HOME/Library/Application Support/JoyHarness/Install Backups/$NAME"
CONFIG="$HOME/Library/Application Support/JoyHarness/config/user.json"

[ -d /Applications/JoyHarness.app ] || { echo "Nothing installed to snapshot" >&2; exit 1; }

mkdir -p "$ARCHIVE"
ditto /Applications/JoyHarness.app "$ARCHIVE/JoyHarness.app"
[ -f "$CONFIG" ] && cp "$CONFIG" "$ARCHIVE/user.json"

git -C "$ROOT_DIR" tag -a "$NAME" -m "$MESSAGE"
echo "Checkpoint '$NAME' saved. Push the tag with: git push <remote> $NAME"
