#!/bin/bash
set -euo pipefail

LABEL="com.yongboxia.joyharness"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_DIR="$HOME/Applications/JoyHarness"

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
pkill -f "$APP_DIR/.venv/bin/python -m src( |$)" 2>/dev/null || true
pkill -f 'Python.app/.*/Python -m src( |$)' 2>/dev/null || true
rm -rf "${TMPDIR:-/tmp}/joyharness-runtime" 2>/dev/null || true

echo "JoyHarness stopped. It will start again at next login unless you remove $PLIST."
