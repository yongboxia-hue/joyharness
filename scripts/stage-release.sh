#!/usr/bin/env bash
# Stage 3 of 3: tag it, let CI build it, and finish the last hop from here.
#
# CI holds the signing key and does the build, the notarisation, the release
# and the appcast. The one thing it cannot do is the last hop: the download
# bucket is in China and GitHub's runners are not, so mirroring is run from
# this side of the link (see scripts/mirror-release-to-cos.sh for the
# measurements). This script waits for the release and then mirrors -- and if
# the machine is asleep or the network is out, the launchd agent installed by
# scripts/install-mirror-agent.sh picks it up later.
#
# Usage: scripts/stage-release.sh 0.2.0

set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 2
fi

# A release is a claim that this exact tree was tried. The acceptance package
# is built from the working tree, so a dirty tree means the thing that was
# tested is not the thing being tagged.
dirty="$(git status --porcelain | grep -v ' CHANGELOG.md$' || true)"
if [ -n "$dirty" ]; then
  echo "The working tree has uncommitted changes outside CHANGELOG.md:" >&2
  echo "$dirty" >&2
  exit 1
fi

installed_version="$(defaults read /Applications/JoyHarness.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo none)"
if [ "$installed_version" != "$version" ]; then
  cat >&2 <<NOTE
/Applications/JoyHarness.app is $installed_version, not $version.

Release what was tried: run scripts/set-version.sh $version and
scripts/stage-accept.sh, press the buttons, and come back.
NOTE
  exit 1
fi

printf '\n\033[1mTagging and pushing\033[0m\n'
bash scripts/prepare-release.sh "$version" --push

printf '\n\033[1mWaiting for the release workflow\033[0m\n'
if command -v gh >/dev/null 2>&1; then
  # Wait for the run *for this tag*. Taking the newest run in the list watched
  # whichever release happened to be most recent -- which, in the seconds
  # before GitHub registers the new one, is the previous release, already
  # finished and green. It then mirrored a release that did not exist yet.
  run=""
  for _ in $(seq 1 30); do
    run="$(gh run list --workflow release.yml --limit 10 \
            --json databaseId,headBranch \
            -q "[.[] | select(.headBranch == \"v$version\")][0].databaseId")"
    [ -n "$run" ] && [ "$run" != "null" ] && break
    sleep 5
  done
  if [ -z "$run" ] || [ "$run" = "null" ]; then
    echo "No release workflow appeared for v$version; nothing has been mirrored." >&2
    exit 1
  fi
  echo "Watching run $run"
  gh run watch "$run" --exit-status || {
    echo "The release workflow did not finish cleanly; nothing has been mirrored." >&2
    exit 1
  }

  # The workflow creates the release near its end, and the feed is committed
  # after that. Mirroring reads both, so wait for them rather than racing.
  for _ in $(seq 1 30); do
    gh release view "v$version" >/dev/null 2>&1 && break
    sleep 5
  done
  git fetch origin main --quiet
fi

printf '\n\033[1mMirroring to the download bucket\033[0m\n'
bash scripts/mirror-release-to-cos.sh "v$version"

printf '\n\033[32mv%s is released and downloadable.\033[0m\n' "$version"
