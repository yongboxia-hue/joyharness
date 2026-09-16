#!/bin/bash
# Prove an upgrade keeps what the user chose.
#
# Compiles ConfigMerge on its own -- it is deliberately free of AppKit and of
# the rest of the app so this can run in a second, because it decides whether
# someone keeps their mappings across an update.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="$ROOT_DIR/build/swift-shadow-toolchain/usr/bin/swiftc"
if [ ! -x "$SWIFTC" ]; then
  SWIFTC="$(xcrun --find swiftc)"
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joyharness-merge-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

"$SWIFTC" \
  -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$ROOT_DIR/macos/JoyHarnessNative/ConfigMerge.swift" \
  "$ROOT_DIR/tests/ConfigUpgradeMergeTests.swift" \
  -o "$WORK_DIR/ConfigUpgradeMergeTests"

"$WORK_DIR/ConfigUpgradeMergeTests"
