#!/usr/bin/env bash
# Where things live inside JoyHarness.app.
#
# The app binary is universal but the Python runtime cannot be (pygame and
# hidapi ship no universal2 wheels), so the bundle carries one runtime per
# architecture under Runtime/<arch>/. Every script that looks for a runtime
# reads the layout from here, and the layout itself comes from the Info.plist
# key the app actually uses at launch — so a path change cannot drift between
# the build script, the installer and the verifiers.

# The one place the runtime's location inside the bundle is written down.
# The build script lays the bundle out from this; the app reads it back from
# the Info.plist key the build script fills in from it.
JOYHARNESS_RUNTIME_TEMPLATE="Runtime/{arch}/JoyHarnessRuntime/JoyHarnessRuntime"

# The runtime path template, with {arch} still in it, as the app reads it.
joyharness_runtime_template() {
  local plist="$1"
  plutil -extract JoyHarnessRuntimeExecutable raw -o - "$plist" 2>/dev/null \
    || echo "$JOYHARNESS_RUNTIME_TEMPLATE"
}

# Path to the runtime executable for one architecture.
joyharness_runtime_executable() {
  local app_path="$1" arch="$2"
  local template
  template="$(joyharness_runtime_template "$app_path/Contents/Info.plist")"
  echo "$app_path/Contents/Resources/${template//\{arch\}/$arch}"
}

# The architectures this bundle actually ships a runtime for.
joyharness_bundled_runtime_archs() {
  local app_path="$1" arch
  for arch in arm64 x86_64; do
    [ -x "$(joyharness_runtime_executable "$app_path" "$arch")" ] && echo "$arch"
  done
  return 0
}

# The architectures the app binary itself can run as.
joyharness_binary_archs() {
  lipo -archs "$1/Contents/MacOS/JoyHarness" 2>/dev/null | tr ' ' '\n' | grep -v '^$'
}

# Every architecture the binary claims must have a runtime to launch.
#
# This is the v0.1.2 failure as an assertion: that build was arm64-only and
# Intel Macs refused to open it. A universal binary with only one runtime
# fails the same way, one step later and less legibly — it opens, then cannot
# start its backend.
joyharness_assert_runtime_coverage() {
  local app_path="$1" arch missing=0
  for arch in $(joyharness_binary_archs "$app_path"); do
    if [ ! -x "$(joyharness_runtime_executable "$app_path" "$arch")" ]; then
      echo "App binary runs as $arch but bundles no $arch runtime." >&2
      missing=1
    fi
  done
  if [ -z "$(joyharness_binary_archs "$app_path")" ]; then
    echo "Cannot read architectures from $app_path/Contents/MacOS/JoyHarness" >&2
    missing=1
  fi
  return $missing
}
