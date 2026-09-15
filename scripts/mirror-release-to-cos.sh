#!/usr/bin/env bash
# Copy a published release into the download bucket the website and the updater
# read.
#
# This is not in release.yml because it cannot be. GitHub's runners are not in
# China and the bucket is: a measured 8MB upload took four timeouts of 143s to
# fail from a runner, and 1.2s from a machine inside the country. Global
# acceleration is the documented fix for exactly that, and a Lighthouse bucket
# cannot have it -- bucket-level configuration is console-only there. So the
# last hop is run from the right side of the link instead.
#
# What that costs is atomicity: between the release being published and this
# running, GitHub has the new version and the website still serves the old one.
# Nothing is broken in that window -- the feed in the bucket still announces the
# old version too, so no one is offered a download that does not exist -- but
# the release is not finished until this succeeds. The site audit runs daily and
# fails while the two disagree, so the window is visible rather than silent.
#
# Safe to re-run: every object is overwritten with the same bytes and read back.
#
# Usage: scripts/mirror-release-to-cos.sh [vX.Y.Z]   (default: latest release)

set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:-}"
[ -n "$tag" ] || tag="$(gh release view --json tagName -q .tagName)"
echo "Mirroring $tag"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release download "$tag" --dir "$work" --pattern '*.dmg' --pattern '*.dmg.sha256'

# The checksum published beside the package, checked before anything is
# uploaded. A truncated download would otherwise be mirrored faithfully and
# then verified against itself at the far end.
( cd "$work" && shasum -a 256 -c ./*.dmg.sha256 )

# The feed comes from the repository, not from this machine: it carries the
# Sparkle signature generated in CI with a key that only CI holds, so there is
# no way to regenerate it here and no reason to.
git fetch origin main --quiet
git show "origin/main:appcast.xml" > "$work/appcast.xml"

announced="$(sed -n 's/.*<sparkle:version>\([^<]*\)<.*/\1/p' "$work/appcast.xml" | head -1)"
if [ "$announced" != "${tag#v}" ]; then
  echo "The feed on origin/main announces $announced, not ${tag#v}." >&2
  echo "Either the release workflow has not committed it yet, or main has" >&2
  echo "moved on. Mirroring now would publish a feed for the wrong release." >&2
  exit 1
fi

python3 scripts/publish-to-cos.py \
  "$work"/*.dmg "$work"/*.dmg.sha256 "$work/appcast.xml" \
  --alias JoyHarness.dmg

echo
echo "$tag is now downloadable and announced from the bucket."
