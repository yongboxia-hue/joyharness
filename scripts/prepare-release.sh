#!/usr/bin/env bash
# Bump the version everywhere it is written down, prove the copies agree, and
# tag it.
#
# The version lives in three files on purpose -- the build stamps it, --version
# prints it, the CHANGELOG announces it -- and verify-native-ui-contract.py
# fails the build if they disagree. What nothing checked was the tag: tagging
# v0.1.9 on a tree that still said 0.1.8 built, signed, notarized and published
# a package containing 0.1.8, and since Sparkle compares CFBundleVersion, it was
# offered to nobody. release.yml now refuses that tag; this script keeps you
# from creating it in the first place.
#
# The release note itself stays hand-written. A version number can be derived;
# what changed and why cannot, and a generated one would be worse than none.
#
# Usage: scripts/prepare-release.sh 0.1.9 [--push]

set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
push="${2:-}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z [--push]" >&2
  exit 2
fi

# CHANGELOG.md is exempt: writing the release note is the first step of a
# release, and making that its own commit before this one was busywork in the
# way of the thing it precedes. Everything else has to be committed, because
# this script makes a commit and it should contain the release and nothing else.
dirty="$(git status --porcelain | grep -v ' CHANGELOG.md$' || true)"
if [ -n "$dirty" ]; then
  echo "The working tree has uncommitted changes outside CHANGELOG.md:" >&2
  echo "$dirty" >&2
  echo "Commit or stash them first -- this commit should contain only the release." >&2
  exit 1
fi

# The CHANGELOG entry is the part a person has to write, so it is the part that
# is checked first: everything below is mechanical and can be redone, while a
# release with no note is already published by the time anyone notices.
if ! grep -q "^## \[$version\]" CHANGELOG.md; then
  echo "CHANGELOG.md has no '## [$version]' entry." >&2
  echo "Write the release note first; the rest of this is mechanical." >&2
  exit 1
fi

newest="$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)"
if [ "$newest" != "$version" ]; then
  echo "CHANGELOG.md's newest entry is $newest, not $version." >&2
  echo "The contract check reads the topmost entry, so $version has to be first." >&2
  exit 1
fi

if git rev-parse "v$version" >/dev/null 2>&1; then
  echo "Tag v$version already exists." >&2
  exit 1
fi

python3 - "$version" <<'PY'
import pathlib
import re
import sys

version = sys.argv[1]
edits = [
    (pathlib.Path("scripts/build-swiftui-macos-app.sh"),
     r'(VERSION="\$\{JOYHARNESS_VERSION:-)[0-9.]+(\})'),
    (pathlib.Path("src/constants.py"),
     r'(__version__ = ")[0-9.]+(")'),
]
for path, pattern in edits:
    text = path.read_text()
    replaced, count = re.subn(pattern, lambda m: m.group(1) + version + m.group(2), text)
    if count != 1:
        raise SystemExit(f"{path}: expected one version to replace, found {count}")
    path.write_text(replaced)
    print(f"  {path} -> {version}")
PY

# The same check CI runs. Running it here means a mismatch is a local failure
# on a clean tree rather than a red build on a tag that then has to be deleted
# from the remote.
verifier=python3
[ -x .venv/bin/python ] && verifier=.venv/bin/python
"$verifier" scripts/verify-native-ui-contract.py

git add CHANGELOG.md src/constants.py scripts/build-swiftui-macos-app.sh
git commit -m "Release $version"
git tag "v$version"

if [ "$push" = "--push" ]; then
  git push origin HEAD:main
  git push origin "v$version"
  echo "Pushed. release.yml is building v$version."
else
  echo
  echo "Committed and tagged. To release:"
  echo "  git push origin main && git push origin v$version"
fi
