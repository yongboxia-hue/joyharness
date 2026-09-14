#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="$ROOT_DIR/build/swift-shadow-toolchain/usr/bin/swiftc"
if [ ! -x "$SWIFTC" ]; then
  SWIFTC="$(xcrun --find swiftc)"
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joyharness-input-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

"$SWIFTC" \
  -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  "$ROOT_DIR/macos/JoyHarnessNative/KeyboardShortcut.swift" \
  "$ROOT_DIR/macos/JoyHarnessNative/InputGateway.swift" \
  "$ROOT_DIR/macos/JoyHarnessNative/InputFocus.swift" \
  "$ROOT_DIR/tests/NativeInputGatewayTests.swift" \
  -framework AppKit \
  -framework CoreGraphics \
  -o "$WORK_DIR/NativeInputGatewayTests"

"$WORK_DIR/NativeInputGatewayTests" "$ROOT_DIR"
