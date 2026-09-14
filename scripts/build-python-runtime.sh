#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${JOYHARNESS_BUILD_PYTHON:-}"
BUILD_ROOT="${JOYHARNESS_RUNTIME_BUILD_DIR:-$ROOT_DIR/build/python-runtime}"
VENV_DIR="$BUILD_ROOT/venv"
WORK_DIR="$BUILD_ROOT/work"
DIST_DIR="$BUILD_ROOT/dist"
OUTPUT_DIR="${JOYHARNESS_RUNTIME_OUTPUT_DIR:-$DIST_DIR/JoyHarnessRuntime}"
SOURCE_SITE_PACKAGES="${JOYHARNESS_RUNTIME_SITE_PACKAGES:-}"
OFFLINE_BUILD="${JOYHARNESS_OFFLINE_BUILD:-0}"

if [ -z "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3.12 || true)"
fi
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
  echo "Python 3.12 is required to build the bundled runtime." >&2
  exit 1
fi

case "$BUILD_ROOT" in
  "$ROOT_DIR"/build/*|/tmp/*|"${TMPDIR:-/tmp}"/*) ;;
  *)
    echo "Refusing to use a runtime build directory outside build or temporary storage: $BUILD_ROOT" >&2
    exit 1
    ;;
esac

mkdir -p "$BUILD_ROOT"
if [ ! -x "$VENV_DIR/bin/python" ]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

INSTALL_REQUIREMENTS=("pyinstaller==6.15.0")
if [ -n "$SOURCE_SITE_PACKAGES" ]; then
  [ -d "$SOURCE_SITE_PACKAGES" ] || {
    echo "Runtime source site-packages not found: $SOURCE_SITE_PACKAGES" >&2
    exit 1
  }
else
  INSTALL_REQUIREMENTS+=(-r "$ROOT_DIR/requirements-macos-runtime.txt")
fi

if command -v uv >/dev/null 2>&1; then
  if [ "$OFFLINE_BUILD" = "1" ]; then
    uv pip install \
      --offline \
      --python "$VENV_DIR/bin/python" \
      "${INSTALL_REQUIREMENTS[@]}"
  else
    uv pip install \
      --python "$VENV_DIR/bin/python" \
      "${INSTALL_REQUIREMENTS[@]}"
  fi
else
  if [ "$OFFLINE_BUILD" = "1" ]; then
    echo "Offline runtime build requires uv and its package cache." >&2
    exit 1
  fi
  "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check \
    --timeout 300 \
    --retries 5 \
    "${INSTALL_REQUIREMENTS[@]}"
fi

rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

PYINSTALLER_PATHS=()
if [ -n "$SOURCE_SITE_PACKAGES" ]; then
  PYINSTALLER_PATHS+=(--paths "$SOURCE_SITE_PACKAGES")
fi

cd "$ROOT_DIR"
# macOS's system /bin/bash is 3.2 (last GPLv2 release Apple ships), where
# "${array[@]}" on an empty array raises "unbound variable" under `set -u`
# even though the array IS declared -- fixed in bash 4.4+, but this script
# has to keep working under 3.2. The `:-` default makes an empty expansion
# safe either way.
"$VENV_DIR/bin/pyinstaller" \
  --noconfirm \
  --clean \
  --onedir \
  --name JoyHarnessRuntime \
  --distpath "$DIST_DIR" \
  --workpath "$WORK_DIR" \
  --specpath "$WORK_DIR" \
  --collect-all pygame \
  --hidden-import hid \
  --hidden-import Cocoa \
  --hidden-import Quartz \
  --hidden-import ApplicationServices \
  --exclude-module tkinter \
  --exclude-module ttkbootstrap \
  --exclude-module pystray \
  --exclude-module PIL \
  "${PYINSTALLER_PATHS[@]+"${PYINSTALLER_PATHS[@]}"}" \
  "$ROOT_DIR/pyinstaller_entry.py" >/dev/null

if [ "$OUTPUT_DIR" != "$DIST_DIR/JoyHarnessRuntime" ]; then
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$(dirname "$OUTPUT_DIR")"
  ditto "$DIST_DIR/JoyHarnessRuntime" "$OUTPUT_DIR"
fi

RUNTIME_EXECUTABLE="$OUTPUT_DIR/JoyHarnessRuntime"
if [ ! -x "$RUNTIME_EXECUTABLE" ]; then
  echo "Bundled runtime executable is missing: $RUNTIME_EXECUTABLE" >&2
  exit 1
fi

JOYHARNESS_INPUT_BACKEND=native \
JOYHARNESS_NATIVE_INPUT_SOCKET="${TMPDIR:-/tmp}/joyharness-runtime-build-missing.sock" \
"$RUNTIME_EXECUTABLE" --native-client --no-admin-warn --config "$ROOT_DIR/config/user.json" --list-controls >/dev/null

echo "Built Python runtime: $OUTPUT_DIR"
