#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="JoyHarness"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$DIST_DIR/${APP_NAME}-dmg"
BUILT_APP="$ROOT_DIR/build/macos-swiftui/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

case "$STAGE_DIR" in
  "$ROOT_DIR"/dist/*) ;;
  *) echo "Unsafe DMG staging path: $STAGE_DIR" >&2; exit 1 ;;
esac

# A DMG is the thing that gets handed to a machine, so it must not be built
# ad-hoc signed by accident. An ad-hoc signature changes on every build, and
# macOS books the Accessibility grant against the signature's designated
# requirement -- so an ad-hoc DMG makes the user re-authorize after every
# install and leaves a dead entry in System Settings each time.
if [ -z "${JOYHARNESS_CODESIGN_IDENTITY:-}" ] && [ "${JOYHARNESS_ALLOW_ADHOC_DMG:-0}" != "1" ]; then
  cat >&2 <<'UNSIGNED'
Refusing to build a DMG without a signing identity.

  export JOYHARNESS_CODESIGN_IDENTITY="Developer ID Application: yongbo xia (7WCWLLYJFQ)"
  bash scripts/build-dmg-installer.sh

Set JOYHARNESS_ALLOW_ADHOC_DMG=1 only for a throwaway CI artifact that will
never be installed on anyone's machine.
UNSIGNED
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR" "$DMG_PATH" "$CHECKSUM_PATH"

# Credentials for notarization. A keychain profile locally:
#   xcrun notarytool store-credentials joyharness \
#     --apple-id <id> --team-id 7WCWLLYJFQ
# or the environment in CI -- see release.yml.
NOTARY_PROFILE="${JOYHARNESS_NOTARY_PROFILE:-joyharness}"
NOTARIZE=0
if [ -n "${JOYHARNESS_NOTARY_APPLE_ID:-}" ] && [ -n "${JOYHARNESS_NOTARY_PASSWORD:-}" ]; then
  # Strip newlines. An app-specific password has none, and a stray trailing
  # newline is the usual result of piping a secret in -- it turns into a 401
  # that reads as a wrong password rather than as a formatting problem.
  NOTARY_APPLE_ID="$(printf '%s' "$JOYHARNESS_NOTARY_APPLE_ID" | tr -d '\r\n')"
  NOTARY_PASSWORD="$(printf '%s' "$JOYHARNESS_NOTARY_PASSWORD" | tr -d '\r\n')"
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID"
               --password "$NOTARY_PASSWORD"
               --team-id "${JOYHARNESS_NOTARY_TEAM_ID:-7WCWLLYJFQ}")
  # An app-specific password is 16 characters plus 3 hyphens. Saying so here
  # costs nothing and names the problem, instead of letting Apple answer 401
  # after the build has already run.
  if [ "${#NOTARY_PASSWORD}" -ne 19 ]; then
    echo "JOYHARNESS_NOTARY_PASSWORD is ${#NOTARY_PASSWORD} characters; an" >&2
    echo "app-specific password is 19 (xxxx-xxxx-xxxx-xxxx). Re-set the secret." >&2
    exit 1
  fi
  NOTARIZE=1
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  NOTARIZE=1
fi

# Check the credentials before building anything. Notarization is the last
# step, so a bad password otherwise surfaces after several minutes of
# compiling and signing -- and in CI, after a whole billed run.
if [ "$NOTARIZE" = "1" ]; then
  if ! xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
    echo "Notarization credentials were rejected by Apple." >&2
    echo "Checked before building, so nothing else has run yet." >&2
    xcrun notarytool history "${NOTARY_ARGS[@]}" 2>&1 | tail -3 >&2
    exit 1
  fi
fi

JOYHARNESS_BUILD_FLAVOR=production \
JOYHARNESS_BUILD_CONFIGURATION=release \
  "$ROOT_DIR/scripts/build-swiftui-macos-app.sh"
"$ROOT_DIR/scripts/verify-swiftui-macos-app.sh" "$BUILT_APP"

# Submit one file and staple the resulting ticket into it.
#
# Both the app and the DMG go through this, separately, and both need to.
# Notarizing the DMG alone leaves the app relying on an online check every
# time it launches -- fine on a good connection, a hang or a refusal on a bad
# one. Stapling writes the ticket into the file so the check works offline.
# $3 is what gets the ticket, when that differs from what was submitted.
# The app is submitted as a zip because notarytool takes a zip, a DMG or a
# pkg -- never a bare bundle -- but a zip cannot hold a ticket, so the staple
# goes onto the bundle itself.
notarize_and_staple() {
  local target="$1" label="$2" staple_target="${3:-$1}"
  echo "Notarizing $label (usually a few minutes)..."
  if ! xcrun notarytool submit "$target" "${NOTARY_ARGS[@]}" --wait --timeout 30m; then
    echo "" >&2
    echo "Notarization failed for $label. Apple lists the reason per file:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$staple_target"
  xcrun stapler validate "$staple_target"
}

if [ "$NOTARIZE" = "1" ]; then
  # The app is submitted zipped: notarytool takes a zip, a DMG or a pkg, not a
  # bare bundle. The ticket is stapled to the bundle itself, not to the zip,
  # so the DMG built below carries an already-stapled app.
  APP_ZIP="$DIST_DIR/JoyHarness-notarize.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$APP_ZIP"
  notarize_and_staple "$APP_ZIP" "the app" "$BUILT_APP"
  rm -f "$APP_ZIP"
fi

mkdir -p "$STAGE_DIR"
ditto "$BUILT_APP" "$STAGE_DIR/$APP_NAME.app"
cp "$ROOT_DIR/scripts/install-macos.sh" "$STAGE_DIR/install-macos.sh"
chmod +x "$STAGE_DIR/install-macos.sh"
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/安装 JoyHarness.command" <<'INSTALLER'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOYHARNESS_APP_SOURCE="$SCRIPT_DIR/JoyHarness.app" \
JOYHARNESS_SKIP_BUILD=1 \
  "$SCRIPT_DIR/install-macos.sh"
echo
read -r -p "按回车键关闭窗口。" _
INSTALLER
chmod +x "$STAGE_DIR/安装 JoyHarness.command"

cat > "$STAGE_DIR/安装说明.txt" <<'README'
JoyHarness 安装说明

1. 拖动 JoyHarness.app 到 Applications，或双击“安装 JoyHarness.command”执行可回滚升级。
2. 应用已内置运行时，安装过程不会下载 Python 或其他依赖。
3. 命令安装器会先校验新版，备份已安装 App，再替换；任何一步失败都会恢复旧版。
4. 首次运行请按 App 内引导完成辅助功能授权和 Joy-Con 蓝牙连接。

旧 Python 运行目录不会在升级时删除，便于验收期间回滚。
README

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

# The DMG needs its own signature and its own ticket.
#
# Gatekeeper checks the DMG when the user opens the download, and that check
# needs a signature on the DMG itself -- an unsigned one reads as "no usable
# signature" no matter how thoroughly the app inside is signed. This was found
# by asserting the outcome rather than trusting that notarization succeeded:
# the submission came back Accepted and the DMG was still rejected.
if [ "$NOTARIZE" = "1" ]; then
  codesign --force --timestamp --sign "$JOYHARNESS_CODESIGN_IDENTITY" "$DMG_PATH"
  notarize_and_staple "$DMG_PATH" "the DMG"

  # Assert what the user's Mac will actually conclude, for both the thing they
  # download and the thing they end up running.
  dmg_verdict="$(spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 || true)"
  if ! printf '%s' "$dmg_verdict" | grep -q 'accepted'; then
    echo "Gatekeeper rejects the DMG:" >&2
    echo "$dmg_verdict" >&2
    exit 1
  fi
  app_verdict="$(spctl -a -t exec -vv "$BUILT_APP" 2>&1 || true)"
  if ! printf '%s' "$app_verdict" | grep -q 'accepted'; then
    echo "Gatekeeper rejects the app:" >&2
    echo "$app_verdict" >&2
    exit 1
  fi
  echo "Notarized and stapled."
  echo "  DMG: $(printf '%s' "$dmg_verdict" | tr '\n' ' ')"
  echo "  App: $(printf '%s' "$app_verdict" | grep -E 'accepted|source=' | tr '\n' ' ')"
else
  cat >&2 <<'UNNOTARIZED'

NOT NOTARIZED. This DMG will stop the user on first launch, who then has to
find "Open Anyway" in System Settings. Fine for a local test build; not fine
for anything published.

To set it up once:
  xcrun notarytool store-credentials joyharness \
    --apple-id <your Apple ID> --team-id 7WCWLLYJFQ

UNNOTARIZED
fi

shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"
echo "Built DMG: $DMG_PATH"
echo "Checksum: $CHECKSUM_PATH"
