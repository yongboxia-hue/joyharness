#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/bundle-layout.sh
source "$ROOT_DIR/scripts/lib/bundle-layout.sh"
VERIFY_DIR="$ROOT_DIR/build/code-identity"
APP_ONE="$VERIFY_DIR/one/JoyHarness.app"
APP_TWO="$VERIFY_DIR/two/JoyHarness.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "macOS code identity verification skipped on non-Darwin host."
  exit 0
fi

case "$VERIFY_DIR" in
  "$ROOT_DIR"/build/*) ;;
  *) echo "Unsafe identity verification directory: $VERIFY_DIR" >&2; exit 1 ;;
esac

rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR/one" "$VERIFY_DIR/two"

APP_PATH="$APP_ONE" \
JOYHARNESS_BUILD_FLAVOR=production \
JOYHARNESS_BUILD_CONFIGURATION=release \
  "$ROOT_DIR/scripts/build-swiftui-macos-app.sh" >/dev/null

APP_PATH="$APP_TWO" \
JOYHARNESS_BUILD_FLAVOR=production \
JOYHARNESS_BUILD_CONFIGURATION=release \
  "$ROOT_DIR/scripts/build-swiftui-macos-app.sh" >/dev/null

DR_ONE="$(codesign -d -r- "$APP_ONE" 2>&1 | sed -n 's/^designated =>/designated =>/p')"
DR_TWO="$(codesign -d -r- "$APP_TWO" 2>&1 | sed -n 's/^designated =>/designated =>/p')"
EXPECTED='designated => identifier "com.yongboxia.joyharness"'

if [ "$DR_ONE" != "$EXPECTED" ] || [ "$DR_TWO" != "$EXPECTED" ]; then
  echo "Production App designated requirement is unstable." >&2
  echo "First:  $DR_ONE" >&2
  echo "Second: $DR_TWO" >&2
  exit 1
fi

for app_path in "$APP_ONE" "$APP_TWO"; do
  joyharness_assert_runtime_coverage "$app_path" || exit 1
  codesign --verify --deep --strict "$app_path"
  for arch in $(joyharness_bundled_runtime_archs "$app_path"); do
    codesign --verify --strict "$(joyharness_runtime_executable "$app_path" "$arch")"
  done
done

echo "JoyHarness production identity verification passed."
echo "$DR_ONE"
