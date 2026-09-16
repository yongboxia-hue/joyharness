#!/usr/bin/env bash
# Install (or remove) the launchd agent that finishes a release from here.
#
# Releasing has one step that cannot run on GitHub's runners -- the download
# bucket is in China and they are not. This agent runs scripts/mirror-watch.sh
# every ten minutes while you are logged in; it does nothing unless GitHub has
# published a release the bucket has not caught up with, and then it mirrors it
# and says so. Which means a release can be started from anywhere and finishes
# itself the next time this machine is awake.
#
# It needs the login keychain for the bucket credentials, so it runs as a user
# agent rather than a daemon: logged out, it does not run, and the release
# simply finishes later.
#
# Usage: scripts/install-mirror-agent.sh [--uninstall]

set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.yongboxia.joyharness.mirror"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/JoyHarness"
REPO="$(pwd)"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO/scripts/mirror-watch.sh</string>
    </array>
    <key>StartInterval</key><integer>600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/mirror-watch.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/mirror-watch.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST_END

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<NOTE
Installed $LABEL.

  Runs:  $REPO/scripts/mirror-watch.sh
  Every: 10 minutes, while you are logged in
  Log:   $LOG_DIR/mirror-watch.log

It mirrors a published release the bucket has not caught up with, and does
nothing otherwise. Remove it with:

  scripts/install-mirror-agent.sh --uninstall
NOTE
