#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${JOYHARNESS_APP_SOURCE:-$ROOT_DIR/build/macos-swiftui/JoyHarness.app}"
QA_ROOT="$(mktemp -d /tmp/joyharness-installer-qa.XXXXXX)"
DESTINATION="$QA_ROOT/Applications/JoyHarness.app"
BACKUPS="$QA_ROOT/backups"
CANDIDATE="$QA_ROOT/candidate/JoyHarness.app"
QA_HOME="$QA_ROOT/home"
LEGACY_CONFIG="$QA_HOME/Applications/JoyHarness/config/user.json"
MIGRATED_CONFIG="$QA_HOME/Library/Application Support/JoyHarness/config/user.json"

cleanup() {
  rm -rf "$QA_ROOT"
}
trap cleanup EXIT

COMMON_ENV=(
  HOME="$QA_HOME"
  JOYHARNESS_SKIP_BUILD=1
  JOYHARNESS_SKIP_STOP=1
  JOYHARNESS_SKIP_LAUNCH=1
  JOYHARNESS_MIGRATE_LEGACY=0
  JOYHARNESS_APP_DESTINATION="$DESTINATION"
  JOYHARNESS_BACKUP_ROOT="$BACKUPS"
)

mkdir -p "$(dirname "$LEGACY_CONFIG")"
cp "$ROOT_DIR/config/user.json" "$LEGACY_CONFIG"

env "${COMMON_ENV[@]}" \
  JOYHARNESS_APP_SOURCE="$SOURCE_APP" \
  "$ROOT_DIR/scripts/install-macos.sh" >/dev/null

[ -x "$DESTINATION/Contents/MacOS/JoyHarness" ]
codesign --verify --deep --strict "$DESTINATION"
cmp "$LEGACY_CONFIG" "$MIGRATED_CONFIG"

mkdir -p "$(dirname "$CANDIDATE")"
ditto "$SOURCE_APP" "$CANDIDATE"
touch "$CANDIDATE/Contents/Resources/rollback-test-marker"
codesign \
  --force \
  --deep \
  --sign - \
  --identifier "com.yongboxia.joyharness" \
  --requirements '=designated => identifier "com.yongboxia.joyharness"' \
  "$CANDIDATE" >/dev/null

if env "${COMMON_ENV[@]}" \
  JOYHARNESS_APP_SOURCE="$CANDIDATE" \
  JOYHARNESS_TEST_FAIL_AFTER_SWITCH=1 \
  "$ROOT_DIR/scripts/install-macos.sh" >/dev/null 2>&1; then
  echo "Installer rollback test did not fail at the requested failpoint." >&2
  exit 1
fi

[ ! -e "$DESTINATION/Contents/Resources/rollback-test-marker" ]
codesign --verify --deep --strict "$DESTINATION"
echo "Transactional installer success and rollback tests passed."
