#!/bin/bash
# The guard that would have caught v0.1.2, tested on synthetic bundles.
#
# v0.1.2 shipped an arm64-only app and Intel Macs refused to open it. The
# check that prevents a repeat lives in lib/bundle-layout.sh, so it needs a
# test of its own -- otherwise the only thing proving it works is that the
# next release happens to be built correctly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/bundle-layout.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Builds a bundle whose binary claims $1 and which ships runtimes for $2...
make_bundle() {
  local name="$1" binary_archs="$2"; shift 2
  local app="$WORK/$name.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>JoyHarnessRuntimeExecutable</key>
  <string>$JOYHARNESS_RUNTIME_TEMPLATE</string>
</dict></plist>
PLIST
  # A real Mach-O, so lipo reads it the way it reads the shipping binary.
  local slices=() arch
  echo 'int main(void){return 0;}' > "$WORK/stub.c"
  for arch in $binary_archs; do
    cc -arch "$arch" -o "$WORK/stub-$arch" "$WORK/stub.c" 2>/dev/null
    slices+=("$WORK/stub-$arch")
  done
  lipo -create "${slices[@]}" -output "$app/Contents/MacOS/JoyHarness"
  for arch in "$@"; do
    local runtime; runtime="$(joyharness_runtime_executable "$app" "$arch")"
    mkdir -p "$(dirname "$runtime")"
    cp "$WORK/stub-$arch" "$runtime" 2>/dev/null || cc -arch "$arch" -o "$runtime" "$WORK/stub.c"
    chmod +x "$runtime"
  done
  echo "$app"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# A universal binary with both runtimes is what we intend to ship.
both="$(make_bundle both "arm64 x86_64" arm64 x86_64)"
joyharness_assert_runtime_coverage "$both" 2>/dev/null || fail "complete universal bundle rejected"
[ "$(joyharness_bundled_runtime_archs "$both" | tr '\n' ' ')" = "arm64 x86_64 " ] \
  || fail "wrong runtime arch list"

# The v0.1.2 shape: fine on the machine that built it, dead on the other one.
arm_only="$(make_bundle armonly "arm64" arm64)"
joyharness_assert_runtime_coverage "$arm_only" 2>/dev/null \
  || fail "single-arch bundle should pass on its own architecture"

# The trap the universal build introduces: the app opens everywhere, then
# cannot start its backend on half of those machines.
half="$(make_bundle half "arm64 x86_64" arm64)"
if joyharness_assert_runtime_coverage "$half" 2>/dev/null; then
  fail "universal binary with one runtime was accepted"
fi

# The layout is read from the bundle, not assumed, so a bundle built under a
# different template still resolves.
custom="$WORK/custom.app"
mkdir -p "$custom/Contents/MacOS" "$custom/Contents/Resources/Elsewhere/arm64"
cat > "$custom/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>JoyHarnessRuntimeExecutable</key>
  <string>Elsewhere/{arch}/Runtime</string>
</dict></plist>
PLIST
[ "$(joyharness_runtime_executable "$custom" arm64)" \
  = "$custom/Contents/Resources/Elsewhere/arm64/Runtime" ] \
  || fail "runtime path not read from the bundle's own Info.plist"

echo "Bundle layout tests passed."
