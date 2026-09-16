#!/usr/bin/env bash
# Stage 2 of 3: build the thing that will ship, install it, and prove it works.
#
# Everything stage-dev checks, plus the one test that needs a real runtime --
# the mapping editor, which is the only automated proof that changing a
# shortcut changes the shortcut. Production flavour, Developer ID signed,
# notarised, stapled, installed over /Applications, so what you try by hand is
# what the release will be.
#
# It does not bump the version: run scripts/set-version.sh first if this is
# meant to be a release candidate. It does not tag anything either -- that is
# stage-release, after you have pressed the buttons yourself.
#
# The one thing left for a person: pick up a Joy-Con and press it. Runtime to
# keystroke is the last leg and no script can hold the controller.
#
# Usage: scripts/stage-accept.sh [--arm64-only]

set -euo pipefail
cd "$(dirname "$0")/.."

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

PYTHON="$(resolve_python)"
IDENTITY="${JOYHARNESS_CODESIGN_IDENTITY:-Developer ID Application: yongbo xia (7WCWLLYJFQ)}"

# A local acceptance build is for this machine, and this machine has one
# architecture. The x86_64 runtime is built on an Intel runner (see
# .github/workflows/runtime-x86_64.yml), so a universal app built here would
# bundle a runtime it cannot run on half the Macs it claims to support -- the
# DMG script refuses that, correctly. The release build gets both from CI.
ARCHS="$(uname -m)"
if [ "${1:-}" != "--arm64-only" ] && [ -n "${JOYHARNESS_RUNTIME_BUNDLE_X86_64:-}" ]; then
  ARCHS="arm64 x86_64"
fi

version="$(sed -n 's/^VERSION="\${JOYHARNESS_VERSION:-\([0-9.]*\)}"/\1/p' scripts/build-swiftui-macos-app.sh | head -1)"
printf '\n\033[1mAcceptance build %s (%s)\033[0m\n' "$version" "$ARCHS"

printf '\n\033[1mChecks that do not need a runtime\033[0m\n'
# --full: this is the build people install, so the slow checks that stage-dev
# skips while iterating -- the process guard's real timeouts, the synthetic
# clicks on a live window -- run here.
bash scripts/stage-dev.sh --full

printf '\n\033[1mBuilding, signing, notarising\033[0m\n'
JOYHARNESS_ARCHS="$ARCHS" JOYHARNESS_CODESIGN_IDENTITY="$IDENTITY" \
  bash scripts/build-dmg-installer.sh

printf '\n\033[1mInstalling\033[0m\n'
bash scripts/install-local.sh

printf '\n\033[1mMapping editor, against the installed build\033[0m\n'
"$PYTHON" scripts/test-mapping-editor.py /Applications/JoyHarness.app

cat <<REPORT

──────────────────────────────────────────────────────────
  Acceptance package $version is installed and verified.
  DMG: dist/JoyHarness.dmg

  Left for a person, because no script can hold a Joy-Con:
    · change a shortcut, save, press the button, watch it fire
    · connect and disconnect a controller; check the battery
    · press ⌘V into the manual shortcut field, ⌘W to close

  When that is good: scripts/stage-release.sh $version
──────────────────────────────────────────────────────────
REPORT
