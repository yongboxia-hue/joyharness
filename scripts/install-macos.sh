#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/bundle-layout.sh
source "$ROOT_DIR/scripts/lib/bundle-layout.sh"
APP_SOURCE="${JOYHARNESS_APP_SOURCE:-$ROOT_DIR/build/macos-swiftui/JoyHarness.app}"
APP_DESTINATION="${JOYHARNESS_APP_DESTINATION:-/Applications/JoyHarness.app}"
BACKUP_ROOT="${JOYHARNESS_BACKUP_ROOT:-$HOME/Library/Application Support/JoyHarness/Install Backups}"
SKIP_BUILD="${JOYHARNESS_SKIP_BUILD:-0}"
SKIP_STOP="${JOYHARNESS_SKIP_STOP:-0}"
SKIP_LAUNCH="${JOYHARNESS_SKIP_LAUNCH:-0}"
MIGRATE_LEGACY="${JOYHARNESS_MIGRATE_LEGACY:-1}"
EXPECTED_BUNDLE_ID="com.yongboxia.joyharness"
LEGACY_LABEL="com.yongboxia.joyharness"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_CONFIG="$HOME/Applications/JoyHarness/config/user.json"
DATA_ROOT="$HOME/Library/Application Support/JoyHarness"
CURRENT_CONFIG="$DATA_ROOT/config/user.json"

case "$APP_DESTINATION" in
  /*/JoyHarness.app) ;;
  *)
    echo "Refusing unsafe destination: $APP_DESTINATION" >&2
    exit 1
    ;;
esac

if [ ! -d "$APP_SOURCE" ]; then
  if [ "$SKIP_BUILD" = "1" ]; then
    echo "Production App not found: $APP_SOURCE" >&2
    exit 1
  fi
  JOYHARNESS_BUILD_FLAVOR=production \
  JOYHARNESS_BUILD_CONFIGURATION=release \
    "$ROOT_DIR/scripts/build-swiftui-macos-app.sh"
fi

validate_app() {
  local app_path="$1"
  local plist="$app_path/Contents/Info.plist"

  [ -f "$plist" ] || { echo "Missing Info.plist: $plist" >&2; return 1; }
  [ -x "$app_path/Contents/MacOS/JoyHarness" ] || { echo "Missing native executable." >&2; return 1; }
  # Refuse a bundle that cannot run here, rather than installing it and
  # letting the failure surface as a blank window later.
  local host_runtime
  host_runtime="$(joyharness_runtime_executable "$app_path" "$(uname -m)")"
  [ -x "$host_runtime" ] || {
    echo "This build has no $(uname -m) runtime: $host_runtime" >&2
    return 1
  }
  [ "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = "$EXPECTED_BUNDLE_ID" ] || {
    echo "Unexpected bundle identifier." >&2
    return 1
  }
  [ "$(plutil -extract JoyHarnessBuildFlavor raw -o - "$plist")" = "production" ] || {
    echo "Installer only accepts a production build." >&2
    return 1
  }
  codesign --verify --deep --strict "$app_path"
}

validate_app "$APP_SOURCE"

DESTINATION_PARENT="$(dirname "$APP_DESTINATION")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_DIRECTORY="$BACKUP_ROOT/$TIMESTAMP"
BACKUP_APP="$BACKUP_DIRECTORY/JoyHarness.app"
STAGED_APP="$DESTINATION_PARENT/.JoyHarness.install.$$"
PREVIOUS_APP="$DESTINATION_PARENT/.JoyHarness.previous.$$"
LEGACY_BACKUP="$BACKUP_DIRECTORY/LegacyLaunchAgent.plist"
CONFIG_BACKUP="$BACKUP_DIRECTORY/LegacyConfig.json"
USE_SUDO=0
PREVIOUS_READY=0
NEW_INSTALLED=0
LEGACY_MOVED=0
CONFIG_MIGRATED=0
INSTALL_SUCCEEDED=0

mkdir -p "$BACKUP_DIRECTORY"
if [ ! -d "$DESTINATION_PARENT" ]; then
  mkdir -p "$DESTINATION_PARENT" 2>/dev/null || sudo mkdir -p "$DESTINATION_PARENT"
fi
if [ ! -w "$DESTINATION_PARENT" ]; then
  USE_SUDO=1
fi

run_destination_command() {
  if [ "$USE_SUDO" = "1" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

stop_process_pattern() {
  local pattern="$1"
  pkill -TERM -f "$pattern" 2>/dev/null || true
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done
  pkill -KILL -f "$pattern" 2>/dev/null || true
}

cleanup_and_rollback() {
  local status=$?
  trap - EXIT

  if [ "$INSTALL_SUCCEEDED" != "1" ]; then
    echo "Installation did not complete; restoring the previous state." >&2
    if [ "$NEW_INSTALLED" = "1" ] && [ -e "$APP_DESTINATION" ]; then
      run_destination_command rm -rf "$APP_DESTINATION" || true
    fi
    if [ "$PREVIOUS_READY" = "1" ] && [ -e "$PREVIOUS_APP" ]; then
      run_destination_command mv "$PREVIOUS_APP" "$APP_DESTINATION" || true
    fi
    if [ "$LEGACY_MOVED" = "1" ] && [ -f "$LEGACY_BACKUP" ]; then
      mkdir -p "$(dirname "$LEGACY_PLIST")"
      cp "$LEGACY_BACKUP" "$LEGACY_PLIST" || true
      launchctl bootstrap "gui/$(id -u)" "$LEGACY_PLIST" 2>/dev/null || true
    fi
    if [ "$CONFIG_MIGRATED" = "1" ] && [ -f "$CURRENT_CONFIG" ]; then
      rm -f "$CURRENT_CONFIG" || true
    fi
  fi

  if [ -e "$STAGED_APP" ]; then
    run_destination_command rm -rf "$STAGED_APP" || true
  fi
  exit "$status"
}
trap cleanup_and_rollback EXIT

echo "Validating and staging JoyHarness..."
run_destination_command rm -rf "$STAGED_APP"
run_destination_command ditto "$APP_SOURCE" "$STAGED_APP"
validate_app "$STAGED_APP"

if [ -d "$APP_DESTINATION" ]; then
  echo "Backing up the installed App to: $BACKUP_APP"
  ditto "$APP_DESTINATION" "$BACKUP_APP"
fi

if [ ! -f "$CURRENT_CONFIG" ] && [ -f "$LEGACY_CONFIG" ]; then
  echo "Migrating the existing JoyHarness configuration."
  /usr/bin/osascript -l JavaScript \
    -e 'ObjC.import("Foundation"); function run(argv) { JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js); return ""; }' \
    "$LEGACY_CONFIG" >/dev/null
  cp "$LEGACY_CONFIG" "$CONFIG_BACKUP"
  mkdir -p "$(dirname "$CURRENT_CONFIG")"
  CONFIG_INCOMING="$CURRENT_CONFIG.incoming.$$"
  cp "$LEGACY_CONFIG" "$CONFIG_INCOMING"
  mv "$CONFIG_INCOMING" "$CURRENT_CONFIG"
  CONFIG_MIGRATED=1
fi

if [ "$MIGRATE_LEGACY" = "1" ] && [ "$APP_DESTINATION" = "/Applications/JoyHarness.app" ] && [ -f "$LEGACY_PLIST" ]; then
  echo "Disabling the legacy LaunchAgent; its plist is retained in the rollback backup."
  cp "$LEGACY_PLIST" "$LEGACY_BACKUP"
  launchctl bootout "gui/$(id -u)" "$LEGACY_PLIST" 2>/dev/null || true
  LEGACY_MOVED=1
  mv "$LEGACY_PLIST" "$LEGACY_BACKUP"
fi

if [ "$SKIP_STOP" != "1" ]; then
  stop_process_pattern "$APP_DESTINATION/Contents/MacOS/JoyHarness"
  stop_process_pattern "$APP_DESTINATION/Contents/Resources/Runtime/"
  stop_process_pattern "$HOME/Applications/JoyHarness/.venv/bin/python -m src"
fi

if [ -e "$APP_DESTINATION" ]; then
  run_destination_command rm -rf "$PREVIOUS_APP"
  run_destination_command mv "$APP_DESTINATION" "$PREVIOUS_APP"
  PREVIOUS_READY=1
fi
run_destination_command mv "$STAGED_APP" "$APP_DESTINATION"
NEW_INSTALLED=1
if [ "${JOYHARNESS_TEST_FAIL_AFTER_SWITCH:-0}" = "1" ]; then
  echo "Intentional installer rollback test failure." >&2
  false
fi
run_destination_command xattr -cr "$APP_DESTINATION" 2>/dev/null || true
validate_app "$APP_DESTINATION"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/Support/lsregister"
if [ ! -x "$LSREGISTER" ]; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
fi
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_DESTINATION" >/dev/null 2>&1 || true
fi

if [ "$SKIP_LAUNCH" != "1" ]; then
  open "$APP_DESTINATION"
fi

INSTALL_SUCCEEDED=1
if [ "$PREVIOUS_READY" = "1" ] && [ -e "$PREVIOUS_APP" ]; then
  run_destination_command rm -rf "$PREVIOUS_APP"
fi

echo "JoyHarness installation completed."
echo "Rollback backup: $BACKUP_DIRECTORY"
echo "The legacy runtime directory was retained and can be removed after the new App is accepted."
