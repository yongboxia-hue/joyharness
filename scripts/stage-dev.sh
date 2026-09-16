#!/usr/bin/env bash
# Stage 1 of 3: the loop you stay in while changing things.
#
# Fast by default, because a loop you wait two minutes for is a loop you stop
# running. One change, one answer, about twenty seconds:
#
#   · the Preview app, built for this machine's architecture only
#   · every check that finishes in about a second
#
# Two checks are left out of that, and they are the two that cost real time:
#
#   · the process guard, which waits on real timeouts -- 64 seconds of sleeping
#   · the hit targets, which launches the app and clicks it with synthetic
#     events, so it also wants the screen to itself
#
# Neither can be hurried and neither catches the kind of mistake you make while
# editing a view, so they run in --full -- which is what stage-accept runs, and
# what you should run before handing a build to anyone.
#
# Preview is its own bundle id, its own config directory, its own login item,
# so none of this touches the JoyHarness you actually use.
#
# The mapping editor test is not here at all: saving a mapping needs the
# runtime to accept it, a preview never starts one, and a test that cannot pass
# in the stage it runs in only teaches people to ignore red. It runs in
# stage-accept, against the installed build.
#
# Usage: scripts/stage-dev.sh [--full] [--no-build]

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

FULL=0
BUILD=1
for argument in "$@"; do
  case "$argument" in
    --full) FULL=1 ;;
    --no-build) BUILD=0 ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

FAILED=()
STARTED_AT=$(date +%s)

run() {
  local label="$1"; shift
  local started ended
  started=$(date +%s)
  if "$@" >/tmp/joyharness-stage-dev.log 2>&1; then
    ended=$(date +%s)
    printf '  \033[32mok\033[0m   %-26s %ss\n' "$label" "$((ended - started))"
  else
    ended=$(date +%s)
    printf '  \033[31mFAIL\033[0m %-26s %ss\n' "$label" "$((ended - started))"
    sed 's/^/       /' /tmp/joyharness-stage-dev.log | tail -20
    FAILED+=("$label")
  fi
}

if [ "$BUILD" = "1" ]; then
  # One architecture while iterating: the other slice doubles the build and
  # cannot run on this machine anyway. --full builds both, because that is what
  # gets packaged.
  if [ "$FULL" = "1" ]; then
    run "build (universal)" bash scripts/build-swiftui-macos-app.sh
  else
    run "build ($(uname -m))" env JOYHARNESS_ARCHS="$(uname -m)" bash scripts/build-swiftui-macos-app.sh
  fi
fi

run "UI contract"            "$PYTHON" scripts/verify-native-ui-contract.py
run "Config upgrade merge"   bash scripts/test-config-upgrade-merge.sh
run "Config and runtime IPC" env PYTHONPATH=. "$PYTHON" tests/test_config_and_runtime_ipc.py
run "Native input client"    env PYTHONPATH=. "$PYTHON" tests/test_native_input_client.py
run "Native ConfigStore"     bash scripts/test-native-config-store.sh
run "Native input gateway"   bash scripts/test-native-input-gateway.sh
run "Menu-bar icon"          bash scripts/test-menubar-icon.sh
run "Diagnostics export"     bash scripts/test-diagnostics-exporter.sh
run "Bundle layout"          bash scripts/test-bundle-layout.sh
run "App bundle and signing" bash scripts/verify-swiftui-macos-app.sh

if [ "$FULL" = "1" ]; then
  run "Process guard and HID" env PYTHONPATH=. "$PYTHON" tests/test_process_guard_and_hid_access.py
  # Wants the app on screen, so it goes last and starts it itself.
  open -a "$APP"
  sleep 3
  run "Hit targets"          bash scripts/verify-native-hit-targets.sh
fi

ELAPSED=$(( $(date +%s) - STARTED_AT ))
printf '\n'
if [ ${#FAILED[@]} -gt 0 ]; then
  printf '\033[31mstage-dev FAILED\033[0m in %ss: %s\n' "$ELAPSED" "${FAILED[*]}"
  exit 1
fi
if [ "$FULL" = "1" ]; then
  printf '\033[32mstage-dev --full passed\033[0m in %ss. Next: scripts/stage-accept.sh\n' "$ELAPSED"
else
  printf '\033[32mstage-dev passed\033[0m in %ss. Before packaging: scripts/stage-dev.sh --full\n' "$ELAPSED"
fi
