#!/usr/bin/env bash
# Write a version number into the three files that carry one. Nothing else.
#
# This used to be the first half of prepare-release.sh, which also commits and
# tags -- so the only way to get a build that calls itself 0.2.0 was to declare
# the release. That is backwards: the package you hand someone to try should
# say the version it will ship as, and the tag should come after they say it is
# good. So the bump is its own step now, and prepare-release.sh checks the
# numbers agree rather than writing them.
#
# The version lives in three places on purpose -- the build stamps it,
# --version prints it, the CHANGELOG announces it -- and
# verify-native-ui-contract.py fails the build if they disagree.
#
# Usage: scripts/set-version.sh 0.2.0

set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 2
fi

if ! grep -q "^## \[$version\]" CHANGELOG.md; then
  cat >&2 <<NOTE
CHANGELOG.md has no '## [$version]' entry.

Write the release note first: it is the one part of a release that cannot be
derived, and a build that calls itself $version while the changelog has never
heard of it is exactly the mismatch the contract check exists to catch.
NOTE
  exit 1
fi

newest="$(sed -n 's/^## \[\([0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)"
if [ "$newest" != "$version" ]; then
  echo "CHANGELOG.md's newest entry is $newest, not $version." >&2
  echo "The contract check reads the topmost entry, so $version has to be first." >&2
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

# The contract check imports the runtime's own modules, so it needs the project
# venv. A git worktree does not have one of its own -- it shares the checkout it
# was made from -- so look there too rather than failing in a way that reads
# like a broken environment.
resolve_python() {
  if [ -n "${JOYHARNESS_PYTHON:-}" ]; then echo "$JOYHARNESS_PYTHON"; return; fi
  if [ -x .venv/bin/python ]; then echo ".venv/bin/python"; return; fi
  local common main_venv
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    main_venv="$(cd "$(dirname "$common")" && pwd)/.venv/bin/python"
    if [ -x "$main_venv" ]; then echo "$main_venv"; return; fi
  fi
  echo python3
}

"$(resolve_python)" scripts/verify-native-ui-contract.py

echo
echo "Now $version everywhere. Build an acceptance package with:"
echo "  scripts/stage-accept.sh"
