#!/usr/bin/env bash
# Mirror the newest release if it has not been mirrored yet. Does nothing the
# rest of the time.
#
# This is the half of a release that cannot run on GitHub's runners: the bucket
# the website and the updater read is in China and the runners are not. Left to
# a person, it is the step that gets forgotten -- and between the release being
# published and this running, the site still serves the old version. So a
# launchd agent runs this every few minutes and it finishes the job whenever
# this machine happens to be awake and online.
#
# Safe to run at any time and as often as you like: it compares what the bucket
# announces with what GitHub published and returns immediately unless they
# differ, and the mirror itself overwrites every object with the same bytes and
# reads them back.
#
# Usage: scripts/mirror-watch.sh [--once]

set -euo pipefail
cd "$(dirname "$0")/.."

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

command -v gh >/dev/null 2>&1 || { log "gh is not installed; nothing to do."; exit 0; }

# Not logged in is normal on a machine that has not been set up for releases;
# it is not an error worth waking anyone over.
if ! gh auth status >/dev/null 2>&1; then
  log "gh is not authenticated; skipping."
  exit 0
fi

published="$(gh release view --json tagName -q .tagName 2>/dev/null || true)"
if [ -z "$published" ]; then
  log "No published release yet."
  exit 0
fi

feed_url="${JOYHARNESS_FEED_URL:-https://joyharness-1305183734.cos.ap-shanghai.myqcloud.com/appcast.xml}"
announced="$(curl --silent --max-time 20 "$feed_url" \
  | sed -n 's/.*<sparkle:version>\([^<]*\)<.*/\1/p' | head -1 || true)"

if [ "$announced" = "${published#v}" ]; then
  log "$published is already mirrored."
  exit 0
fi

log "Bucket announces ${announced:-nothing}, GitHub has $published. Mirroring."
if bash scripts/mirror-release-to-cos.sh "$published"; then
  log "Mirrored $published."
  # A release finishing unattended is worth one line on screen -- silent
  # success is indistinguishable from an agent that never ran.
  osascript -e "display notification \"$published 已经可以下载了\" with title \"JoyHarness\"" 2>/dev/null || true
else
  log "Mirroring $published failed; will try again on the next run."
  exit 1
fi
