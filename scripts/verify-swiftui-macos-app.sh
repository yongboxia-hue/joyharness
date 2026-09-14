#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/bundle-layout.sh
source "$ROOT_DIR/scripts/lib/bundle-layout.sh"
APP_PATH="${1:-${APP_PATH:-$ROOT_DIR/build/macos-swiftui/JoyHarness Preview.app}}"
if [ -z "${EXPECTED_BUNDLE_ID:-}" ]; then
  if [ "$(basename "$APP_PATH")" = "JoyHarness.app" ]; then
    EXPECTED_BUNDLE_ID="com.yongboxia.joyharness"
  else
    EXPECTED_BUNDLE_ID="com.yongboxia.joyharness.preview"
  fi
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Missing app: $APP_PATH" >&2
  exit 1
fi

PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/JoyHarness"
RESOURCES="$APP_PATH/Contents/Resources"

plutil -lint "$PLIST" >/dev/null

actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
if [ "$actual_bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
  echo "Unexpected Bundle ID: $actual_bundle_id" >&2
  exit 1
fi

if [ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" != "13.0" ]; then
  echo "Unexpected deployment target." >&2
  exit 1
fi

for path in \
  "$EXECUTABLE" \
  "$RESOURCES/JoyHarness.icns" \
  "$RESOURCES/JoyHarnessAppIcon.png" \
  "$RESOURCES/DefaultConfig.json" \
  "$RESOURCES/JoyConLeft.png" \
  "$RESOURCES/JoyConRight.png" \
  "$RESOURCES/JoyConPair.png" \
  "$RESOURCES/controller-hotspots.json"; do
  if [ ! -e "$path" ]; then
    echo "Missing required bundle resource: $path" >&2
    exit 1
  fi
done

codesign --verify --strict --verbose=2 "$APP_PATH"
# The designated requirement is what the Accessibility grant is keyed to, so
# it has to name something that survives rebuilds. Two forms do:
#   - ad-hoc: identifier alone, pinned by --requirements at signing time
#   - Developer ID: identifier plus the team OU, which outlives even a
#     certificate renewal
# Anything else (a bare leaf-certificate hash, say) would cost the user their
# authorization on every rebuild.
designated_requirement="$(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^designated =>/designated =>/p')"
case "$designated_requirement" in
  "designated => identifier \"$EXPECTED_BUNDLE_ID\"") ;;
  "designated => identifier \"$EXPECTED_BUNDLE_ID\""*"subject.OU] = \""*"\"") ;;
  *)
  echo "Unstable designated requirement: $designated_requirement" >&2
  exit 1
  ;;
esac

if ! otool -L "$EXECUTABLE" | grep -q '/SwiftUI.framework/'; then
  echo "SwiftUI framework is not linked." >&2
  exit 1
fi

build_flavor="$(plutil -extract JoyHarnessBuildFlavor raw -o - "$PLIST")"
if [ "$build_flavor" = "production" ]; then
  if ! joyharness_assert_runtime_coverage "$APP_PATH"; then
    exit 1
  fi
  for runtime_arch in $(joyharness_bundled_runtime_archs "$APP_PATH"); do
    runtime_executable="$(joyharness_runtime_executable "$APP_PATH" "$runtime_arch")"
    actual="$(lipo -archs "$runtime_executable" | tr -d ' ')"
    if [ "$actual" != "$runtime_arch" ]; then
      echo "Runtime under $runtime_arch/ is actually $actual." >&2
      exit 1
    fi
  done
  if [ "$(plutil -extract JoyHarnessRuntimePath raw -o - "$PLIST")" != "~/Library/Application Support/JoyHarness" ]; then
    echo "Production App uses the wrong runtime data path." >&2
    exit 1
  fi
  if [ "$(plutil -extract JoyHarnessIPCPath raw -o - "$PLIST")" != "~/Library/Application Support/JoyHarness/ipc" ]; then
    echo "Production App uses the wrong IPC path." >&2
    exit 1
  fi
fi

echo "SwiftUI app verification passed."
echo "Architectures: $(joyharness_binary_archs "$APP_PATH" | tr '\n' ' ')"
echo "App: $APP_PATH"
echo "Bundle ID: $actual_bundle_id"
echo "$designated_requirement"
