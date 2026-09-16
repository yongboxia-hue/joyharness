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
SUPPORT="$HOME/Library/Application Support/JoyHarness/mirror"
REPO="$(pwd)"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$HOME/Library/Application Support/JoyHarness/mirror"
  echo "Removed $LABEL."
  exit 0
fi

# launchd stores an absolute path, and a worktree is a temporary directory by
# design -- an agent installed from one keeps pointing at a path that will not
# exist after the branch is merged and the worktree removed. Install from the
# checkout that stays.
common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
this_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
if [ -n "$common_dir" ] && [ "$common_dir" != "$this_dir" ]; then
  main_checkout="$(cd "$(dirname "$common_dir")" && pwd)"
  cat >&2 <<NOTE
This is a worktree, and launchd would remember its path after it is gone.

Install from the main checkout instead, once this branch is merged:

  cd $main_checkout && scripts/install-mirror-agent.sh
NOTE
  exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$SUPPORT"

# A launchd agent cannot read ~/Documents. macOS guards it the same way it
# guards Photos and Mail, and a background job has no app to raise a prompt on
# its behalf, so it simply gets "Operation not permitted" -- which is how this
# agent failed silently the first time it was installed. The way out is not to
# ask for Full Disk Access for /bin/bash but to keep everything the agent
# touches somewhere it is allowed to look.
#
# So: the scripts are copied, and the repository is cloned, into Application
# Support. The clone only ever fetches -- it is where appcast.xml is read from,
# which has to come from origin/main because it carries a signature made by a
# key only CI holds.
cp scripts/mirror-watch.sh scripts/mirror-release-to-cos.sh scripts/publish-to-cos.py "$SUPPORT/"
chmod +x "$SUPPORT/mirror-watch.sh" "$SUPPORT/mirror-release-to-cos.sh"
mkdir -p "$SUPPORT/repo/scripts"
cp scripts/mirror-release-to-cos.sh scripts/publish-to-cos.py "$SUPPORT/repo/scripts/"
chmod +x "$SUPPORT/repo/scripts/mirror-release-to-cos.sh"
if [ ! -d "$SUPPORT/repo/.git" ]; then
  git clone --quiet --depth 50 --branch main "$(git remote get-url origin)" "$SUPPORT/repo.clone"
  cp -R "$SUPPORT/repo.clone/.git" "$SUPPORT/repo/.git"
  rm -rf "$SUPPORT/repo.clone"
  git -C "$SUPPORT/repo" checkout --quiet -- . 2>/dev/null || true
  cp scripts/mirror-release-to-cos.sh scripts/publish-to-cos.py "$SUPPORT/repo/scripts/"
  chmod +x "$SUPPORT/repo/scripts/mirror-release-to-cos.sh"
fi

cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SUPPORT/mirror-watch.sh</string>
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

  Runs:  $SUPPORT/mirror-watch.sh
  Repo:  $SUPPORT/repo  (a fetch-only clone; ~/Documents is off limits to
         background agents, so nothing under it is touched)
  Every: 10 minutes, while you are logged in
  Log:   $LOG_DIR/mirror-watch.log

It mirrors a published release the bucket has not caught up with, and does
nothing otherwise. Remove it with:

  scripts/install-mirror-agent.sh --uninstall
NOTE
