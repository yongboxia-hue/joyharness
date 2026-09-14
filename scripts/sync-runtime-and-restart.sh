#!/bin/bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications/JoyHarness"
PYTHON_BIN="$APP_DIR/.venv/bin/python"

if [ ! -x "$PYTHON_BIN" ]; then
  echo "Missing runtime Python: $PYTHON_BIN" >&2
  echo "Run the installer first: bash scripts/install-macos.sh" >&2
  exit 1
fi

echo "Syncing JoyHarness to $APP_DIR ..."
rsync -a --delete \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='logs' \
  --exclude='__pycache__' \
  "$SRC_DIR/" "$APP_DIR/"

chmod +x "$APP_DIR/start.command" 2>/dev/null || true
chmod +x "$APP_DIR/scripts/"*.sh 2>/dev/null || true

echo "Verifying runtime config ..."
"$PYTHON_BIN" -m src --config "$APP_DIR/config/user.json" --list-controls

echo "Restarting via authorized launcher ..."
"$APP_DIR/scripts/restart-joyharness-authorized.sh"
