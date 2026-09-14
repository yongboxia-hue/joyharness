#!/bin/bash
set -euo pipefail

APP_DIR="$HOME/Applications/JoyHarness"
PYTHON_BIN="$APP_DIR/.venv/bin/python"

"$APP_DIR/scripts/stop-joyharness.sh" >/dev/null 2>&1 || true
"$APP_DIR/scripts/start-joyharness.sh"

for _ in {1..20}; do
  # start-joyharness.sh launches with a trailing --native-client flag, so
  # this must allow -m src to be followed by more argv, not just
  # end-of-string -- an exact "$" anchor here never matches and made this
  # loop always time out even on a successful restart.
  if pgrep -f "^$PYTHON_BIN -m src( |$)" >/dev/null 2>&1 ||
     pgrep -f '^.*Python.app/.*/Python -m src( |$)' >/dev/null 2>&1; then
    echo "JoyHarness restarted."
    exit 0
  fi
  sleep 0.5
done

echo "JoyHarness restart was requested, but no running process was detected." >&2
exit 1
