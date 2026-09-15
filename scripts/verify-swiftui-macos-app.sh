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

# Bundled artwork has to stay sharp on a Retina screen: at least twice the
# largest frame it is drawn in. The build scales the masters down to exactly
# that, so this is the check that keeps a future "make it smaller" from
# quietly making the interface look soft -- the kind of regression nobody
# notices in a diff and everybody notices on screen.
#
# The frames come from macos/JoyHarnessNative; grep the resource name to find
# where each is used.
check_image_is_sharp_enough() {
  local name="$1" needed_width="$2" needed_height="$3"
  local file="$RESOURCES/$name.png"
  if [ ! -f "$file" ]; then
    echo "Missing bundled image: $file" >&2
    exit 1
  fi
  local width height
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/{print $2}')"
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/{print $2}')"
  if [ "$width" -lt "$needed_width" ] || [ "$height" -lt "$needed_height" ]; then
    echo "$name.png is ${width}x${height}, below the ${needed_width}x${needed_height}" >&2
    echo "needed to stay sharp at 2x. It would look soft on a Retina display." >&2
    exit 1
  fi
}
# 94pt icon, 390x320pt illustration, and the two controllers at 410pt tall.
check_image_is_sharp_enough JoyHarnessAppIcon 188 188
check_image_is_sharp_enough JoyConPair 780 640
check_image_is_sharp_enough JoyConLeft 420 820
check_image_is_sharp_enough JoyConRight 396 820

# The bundled runtime must carry the entitlement that lets libffi allocate
# executable memory. Without it PyObjC's import spins forever under Hardened
# Runtime and the backend never finishes starting -- it looks like a service
# that "just doesn't run", with nothing in the log after the config line.
# Signing is easy to get subtly wrong, and the symptom appears only on the
# architecture you are not testing on, so it is checked on the built bundle.
for runtime_arch in $(joyharness_bundled_runtime_archs "$APP_PATH"); do
  runtime_binary="$(joyharness_runtime_executable "$APP_PATH" "$runtime_arch")"
  if ! codesign -d --entitlements - --xml "$runtime_binary" 2>/dev/null \
       | plutil -convert xml1 -o - - 2>/dev/null \
       | grep -q 'allow-unsigned-executable-memory'; then
    echo "The $runtime_arch runtime is missing" >&2
    echo "com.apple.security.cs.allow-unsigned-executable-memory." >&2
    echo "PyObjC will hang on import under Hardened Runtime." >&2
    exit 1
  fi
done

echo "SwiftUI app verification passed."
echo "Architectures: $(joyharness_binary_archs "$APP_PATH" | tr '\n' ' ')"
echo "App: $APP_PATH"
echo "Bundle ID: $actual_bundle_id"
echo "$designated_requirement"
