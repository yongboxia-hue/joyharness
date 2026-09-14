#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/build/tests"
EXECUTABLE="$OUTPUT_DIR/menu-bar-icon-tests"
SWIFTC="$(xcrun --find swiftc)"
SHADOW_SWIFTC="$ROOT_DIR/build/swift-shadow-toolchain/usr/bin/swiftc"

if [ -x "$SHADOW_SWIFTC" ]; then
  SWIFTC="$SHADOW_SWIFTC"
elif [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] \
  && [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  "$ROOT_DIR/scripts/build-swiftui-macos-app.sh" >/dev/null
  SWIFTC="$SHADOW_SWIFTC"
fi

mkdir -p "$OUTPUT_DIR"
"$SWIFTC" \
  -target "$(uname -m)-apple-macos13.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit \
  "$ROOT_DIR/macos/JoyHarnessNative/MenuBarIcon.swift" \
  "$ROOT_DIR/tests/MenuBarIconTests.swift" \
  -o "$EXECUTABLE"
"$EXECUTABLE" "$OUTPUT_DIR/menu-bar-icon-preview.png"
