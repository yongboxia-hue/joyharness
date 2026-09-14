#!/bin/bash
set -euo pipefail

LABEL="com.yongboxia.joyharness"
APP_DIR="$HOME/Applications/JoyHarness"
PYTHON_BIN="$APP_DIR/.venv/bin/python"
LOG_DIR="$APP_DIR/logs"
APP_LOG="$LOG_DIR/joyharness-app.log"

if pgrep -f "^$PYTHON_BIN -m src( |$)" >/dev/null 2>&1 ||
   pgrep -f '^.*Python.app/.*/Python -m src( |$)' >/dev/null 2>&1; then
  echo "JoyHarness is already running."
  exit 0
fi

if [ ! -x "$PYTHON_BIN" ]; then
  echo "Missing virtualenv Python: $PYTHON_BIN"
  echo "Run: bash $APP_DIR/scripts/install-macos.sh"
  exit 1
fi

mkdir -p "$LOG_DIR"
cd "$APP_DIR"
echo "$(date '+%Y-%m-%d %H:%M:%S') Starting JoyHarness manually..." >> "$APP_LOG"
# This is invoked from the native SwiftUI app's own "启动服务" button
# (AppModel.startService(), Preview flavor). --native-client and the
# JOYHARNESS_INPUT_BACKEND/JOYHARNESS_NATIVE_INPUT_SOCKET env vars must
# match exactly what RuntimeManager.swift sets for its own (production)
# launch, so both paths synthesize keystrokes through the same, single
# InputGateway.swift implementation instead of two divergent ones.
IPC_DIR="${JOYHARNESS_IPC_DIR:-${TMPDIR:-/tmp}/joyharness-runtime}"
JOYHARNESS_INPUT_BACKEND="native" \
JOYHARNESS_IPC_DIR="$IPC_DIR" \
JOYHARNESS_NATIVE_INPUT_SOCKET="$IPC_DIR/input.sock" \
nohup "$PYTHON_BIN" -m src --native-client >> "$APP_LOG" 2>&1 &

echo "JoyHarness started."
