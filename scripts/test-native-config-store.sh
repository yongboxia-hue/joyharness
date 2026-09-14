#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="$ROOT_DIR/build/swift-shadow-toolchain/usr/bin/swiftc"
if [ ! -x "$SWIFTC" ]; then
  SWIFTC="$(xcrun --find swiftc)"
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joyharness-config-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

"$SWIFTC" \
  -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$ROOT_DIR/macos/JoyHarnessNative/RuntimeClient.swift" \
  "$ROOT_DIR/macos/JoyHarnessNative/ConfigStore.swift" \
  "$ROOT_DIR/tests/NativeConfigStoreTests.swift" \
  -o "$WORK_DIR/NativeConfigStoreTests"

"$WORK_DIR/NativeConfigStoreTests"
