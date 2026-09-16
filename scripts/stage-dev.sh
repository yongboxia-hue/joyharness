#!/usr/bin/env bash
# Stage 1 of 3: the loop you stay in while changing things.
#
# Builds the Preview app -- its own bundle id, its own config directory, its
# own login item -- so nothing here touches the JoyHarness you actually use.
# Then runs every check that does not need a runtime.
#
# What it deliberately does not run is the mapping-editor test: saving a
# mapping needs the runtime to accept it, a preview never starts one, and a
# test that cannot pass here would only teach you to ignore it. That one runs
# in stage-accept.
#
# Usage: scripts/stage-dev.sh [--no-build]

set -euo pipefail
cd "$(dirname "$0")/.."

# The contract check imports the runtime's own modules, so it needs the project
# venv. A git worktree does not have one of its own -- it shares the checkout it
# was made from -- so look there too rather than failing in a way that reads
# like a broken environment.
resolve_python() {
  if [ -n "${JOYHARNESS_PYTHON:-}" ]; then echo "$JOYHARNESS_PYTHON"; return; fi
  if [ -x .venv/bin/python ]; then echo ".venv/bin/python"; return; fi
  local common main_venv
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    main_venv="$(cd "$(dirname "$common")" && pwd)/.venv/bin/python"
    if [ -x "$main_venv" ]; then echo "$main_venv"; return; fi
  fi
  echo python3
}

PYTHON="$(resolve_python)"
APP="$(pwd)/build/macos-swiftui/JoyHarness Preview.app"

FAILED=()

run() {
  local label="$1"; shift
  printf '\n\033[1m%s\033[0m\n' "$label"
  if "$@"; then
    return 0
  fi
  FAILED+=("$label")
}

if [ "${1:-}" != "--no-build" ]; then
  printf '\n\033[1mBuilding Preview\033[0m\n'
  bash scripts/build-swiftui-macos-app.sh >/dev/null
  echo "  $APP"
fi

run "UI contract"            "$PYTHON" scripts/verify-native-ui-contract.py
run "Config and runtime IPC" env PYTHONPATH=. "$PYTHON" tests/test_config_and_runtime_ipc.py
run "Native input client"    env PYTHONPATH=. "$PYTHON" tests/test_native_input_client.py
run "Process guard and HID"  env PYTHONPATH=. "$PYTHON" tests/test_process_guard_and_hid_access.py
run "Config upgrade merge"   bash scripts/test-config-upgrade-merge.sh
run "Native ConfigStore"     bash scripts/test-native-config-store.sh
run "Native input gateway"   bash scripts/test-native-input-gateway.sh
run "Menu-bar icon"          bash scripts/test-menubar-icon.sh
run "Diagnostics export"     bash scripts/test-diagnostics-exporter.sh
run "Bundle layout"          bash scripts/test-bundle-layout.sh
run "App bundle and signing" bash scripts/verify-swiftui-macos-app.sh

# Needs the app on screen, so it goes last and starts it itself.
open -a "$APP"
sleep 3
run "Hit targets"            bash scripts/verify-native-hit-targets.sh

printf '\n'
if [ ${#FAILED[@]} -gt 0 ]; then
  printf '\033[31mstage-dev FAILED\033[0m: %s\n' "${FAILED[*]}"
  exit 1
fi
printf '\033[32mstage-dev passed.\033[0m Next: scripts/stage-accept.sh\n'
