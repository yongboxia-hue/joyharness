#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/bundle-layout.sh
source "$ROOT_DIR/scripts/lib/bundle-layout.sh"
cd "$ROOT_DIR"

BUILD_FLAVOR="${JOYHARNESS_BUILD_FLAVOR:-preview}"
BUILD_CONFIGURATION="${JOYHARNESS_BUILD_CONFIGURATION:-debug}"
# The version the app reports. Keep it equal to the newest heading in
# CHANGELOG.md -- verify-native-ui-contract.py asserts that. Building exactly
# the way a hand-maintained doc once stamped 0.2.0 onto a 0.1.0 tree, so the
# 关于 page and the changelog disagreed about what the user was running.
VERSION="${JOYHARNESS_VERSION:-0.2.1}"

if [ "$BUILD_FLAVOR" = "production" ]; then
  APP_NAME="JoyHarness"
  BUNDLE_ID="com.yongboxia.joyharness"
  RUNTIME_DIR="${RUNTIME_DIR:-~/Library/Application Support/JoyHarness}"
  IPC_DIR="${IPC_DIR:-~/Library/Application Support/JoyHarness/ipc}"
else
  APP_NAME="JoyHarness Preview"
  BUNDLE_ID="com.yongboxia.joyharness.preview"
  RUNTIME_DIR="${RUNTIME_DIR:-$HOME/Applications/JoyHarness}"
  IPC_DIR="${IPC_DIR:-${TMPDIR:-/tmp}/joyharness-runtime}"
fi

DEFAULT_APP_PATH="$ROOT_DIR/build/macos-swiftui/$APP_NAME.app"
APP_PATH="${APP_PATH:-$DEFAULT_APP_PATH}"
EXECUTABLE_NAME="JoyHarness"
SOURCE_DIR="$ROOT_DIR/macos/JoyHarnessNative"
RESOURCE_DIR="$APP_PATH/Contents/Resources"
EXECUTABLE_DIR="$APP_PATH/Contents/MacOS"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLT_SWIFT_INCLUDE="/Library/Developer/CommandLineTools/usr/include/swift"
SWIFTC="$(xcrun --find swiftc)"

case "$APP_PATH" in
  "$ROOT_DIR"/build/*|/tmp/*|"${TMPDIR:-/tmp}"/*) ;;
  *)
    echo "Refusing to replace an app outside the build or temporary directory: $APP_PATH" >&2
    exit 1
    ;;
esac

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Missing swiftc. Install Xcode Command Line Tools first." >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$EXECUTABLE_DIR" "$RESOURCE_DIR"

SWIFT_SOURCES=("$SOURCE_DIR"/*.swift)
if [ -f "$CLT_SWIFT_INCLUDE/module.modulemap" ] && [ -f "$CLT_SWIFT_INCLUDE/bridging.modulemap" ]; then
  SHADOW_TOOLCHAIN="$ROOT_DIR/build/swift-shadow-toolchain"
  SHADOW_BIN="$SHADOW_TOOLCHAIN/usr/bin"
  SHADOW_INCLUDE="$SHADOW_TOOLCHAIN/usr/include"
  SHADOW_LIB="$SHADOW_TOOLCHAIN/usr/lib"
  mkdir -p "$SHADOW_BIN" "$SHADOW_INCLUDE" "$SHADOW_LIB"

  if [ ! -x "$SHADOW_BIN/swift-frontend" ]; then
    cp -c /Library/Developer/CommandLineTools/usr/bin/swift-frontend "$SHADOW_BIN/swift-frontend" \
      2>/dev/null || cp /Library/Developer/CommandLineTools/usr/bin/swift-frontend "$SHADOW_BIN/swift-frontend"
  fi
  if [ ! -x "$SHADOW_BIN/swift-driver-new" ]; then
    cp -c /Library/Developer/CommandLineTools/usr/bin/swift-driver "$SHADOW_BIN/swift-driver-new" \
      2>/dev/null || cp /Library/Developer/CommandLineTools/usr/bin/swift-driver "$SHADOW_BIN/swift-driver-new"
  fi
  if [ ! -e "$SHADOW_BIN/swiftc" ]; then
    ln -s swift-frontend "$SHADOW_BIN/swiftc"
  fi
  if [ ! -e "$SHADOW_LIB/swift" ]; then
    ln -s /Library/Developer/CommandLineTools/usr/lib/swift "$SHADOW_LIB/swift"
  fi
  if [ ! -f "$SHADOW_INCLUDE/swift/bridging.modulemap" ]; then
    cp -R /Library/Developer/CommandLineTools/usr/include/. "$SHADOW_INCLUDE/"
  fi
  if [ -f "$SHADOW_INCLUDE/swift/module.modulemap" ]; then
    mv "$SHADOW_INCLUDE/swift/module.modulemap" "$SHADOW_INCLUDE/swift/module.modulemap.disabled"
  fi
  SWIFTC="$SHADOW_BIN/swiftc"
fi
if [ "$BUILD_CONFIGURATION" = "release" ]; then
  SWIFT_OPTIMIZATION=(-O -whole-module-optimization)
else
  SWIFT_OPTIMIZATION=(-Onone)
fi
# 两个架构各编一次再合成。只编本机架构的包在另一种 Mac 上根本打不开 ——
# v0.1.2 就是这样：arm64 的包在 Intel 机器上报"这台 Mac 不支持此应用程序"。
# Swift 这边交叉编译是现成的，SDK 里两个切片都有。
# 设 JOYHARNESS_ARCHS 可以只编一个（比如本机快速迭代）。
# Sparkle, for in-app updates.
#
# Pinned and checksummed rather than "latest": an updater is the one component
# that can replace the whole app on a user's machine, so what goes into the
# build should not change because upstream published something today.
#
# Cached under build/, not committed -- 2.9MB of binary in git for something
# reproducible from a URL and a hash.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_DIR="$ROOT_DIR/build/sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "Fetching Sparkle $SPARKLE_VERSION..."
  mkdir -p "$SPARKLE_DIR"
  archive="$SPARKLE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$archive" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [ "$actual" != "$SPARKLE_SHA256" ]; then
    echo "Sparkle archive checksum mismatch." >&2
    echo "  expected $SPARKLE_SHA256" >&2
    echo "  actual   $actual" >&2
    rm -f "$archive"
    exit 1
  fi
  tar -xf "$archive" -C "$SPARKLE_DIR"
fi
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework missing after fetch." >&2; exit 1; }

JOYHARNESS_ARCHS="${JOYHARNESS_ARCHS:-arm64 x86_64}"
SLICE_DIR="$ROOT_DIR/build/swift-slices"
rm -rf "$SLICE_DIR" && mkdir -p "$SLICE_DIR"
SLICES=()
for arch in $JOYHARNESS_ARCHS; do
  "$SWIFTC" \
    -parse-as-library \
    "${SWIFT_OPTIMIZATION[@]}" \
    -target "$arch-apple-macos13.0" \
    -sdk "$SDK_PATH" \
    -F "$SPARKLE_DIR" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    "${SWIFT_SOURCES[@]}" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -o "$SLICE_DIR/$arch"
  SLICES+=("$SLICE_DIR/$arch")
done
lipo -create "${SLICES[@]}" -output "$EXECUTABLE_DIR/$EXECUTABLE_NAME"
FRAMEWORK_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORK_DIR"
rm -rf "$FRAMEWORK_DIR/Sparkle.framework"
# ditto, not cp: the framework is full of symlinks (Versions/Current and the
# top-level aliases), and flattening them produces a bundle codesign refuses.
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORK_DIR/Sparkle.framework"

echo "Swift binary architectures: $(lipo -archs "$EXECUTABLE_DIR/$EXECUTABLE_NAME")"

SELECTED_ICON="$ROOT_DIR/assets/controller/app-icon.png"

# The artwork in assets/ stays at full resolution -- the .icns below is built
# from it and needs every size up to 1024, and it is the master for anything
# rendered later. What gets bundled is scaled to what the interface actually
# shows, at 2x for Retina and no more.
#
# Copying the masters verbatim shipped 2.3MB of pixels to draw a 94pt icon and
# a 390pt illustration: the app icon alone was a 1024x1024 image displayed at
# 94pt, which is 5x more than the densest screen can use.
#
# Each number below is twice the largest frame the image appears in; grep the
# name in macos/JoyHarnessNative to find it. verify-swiftui-macos-app.sh
# checks the bundled sizes against those frames, so shrinking one too far
# fails the build rather than going soft on a Retina display.
scale_into() {
  local source="$1" longest_edge="$2" destination="$3"
  sips -Z "$longest_edge" "$source" --out "$destination" >/dev/null
}
scale_into "$SELECTED_ICON" 256 "$RESOURCE_DIR/JoyHarnessAppIcon.png"
scale_into "$ROOT_DIR/assets/controller/joycon-left.png" 880 "$RESOURCE_DIR/JoyConLeft.png"
scale_into "$ROOT_DIR/assets/controller/joycon-right.png" 906 "$RESOURCE_DIR/JoyConRight.png"
scale_into "$ROOT_DIR/assets/controller/joycon-pair.png" 1024 "$RESOURCE_DIR/JoyConPair.png"
cp "$ROOT_DIR/assets/controller/hotspots.json" "$RESOURCE_DIR/controller-hotspots.json"
cp "$ROOT_DIR/config/user.json" "$RESOURCE_DIR/DefaultConfig.json"

if [ "$BUILD_FLAVOR" = "production" ]; then
  BUNDLED_RUNTIME="${JOYHARNESS_RUNTIME_BUNDLE:-$ROOT_DIR/build/python-runtime/dist/JoyHarnessRuntime}"
  RUNTIME_BINARY="$BUNDLED_RUNTIME/JoyHarnessRuntime"
  # Rebuild whenever any runtime source is newer than the bundled binary.
  # Testing only for existence meant an edit to src/ shipped a months-old
  # runtime without a word: the app launched, the Swift side was current,
  # and the Python half silently was not.
  NEEDS_RUNTIME_BUILD=0
  if [ ! -x "$RUNTIME_BINARY" ]; then
    NEEDS_RUNTIME_BUILD=1
  elif [ -n "$(find "$ROOT_DIR/src" "$ROOT_DIR/scripts/build-python-runtime.sh" \
                    -newer "$RUNTIME_BINARY" -print -quit 2>/dev/null)" ]; then
    echo "Runtime sources changed since the last runtime build; rebuilding."
    NEEDS_RUNTIME_BUILD=1
  fi
  if [ "$NEEDS_RUNTIME_BUILD" = "1" ]; then
    "$ROOT_DIR/scripts/build-python-runtime.sh"
  fi
  # Runtime 没法做成 universal：hidapi 只发分架构的轮子，
  # 没有 universal2，所以 PyInstaller 一次只能产出一个切片。两份都带上，
  # 由 RuntimeManager 在启动时按自己的进程架构挑。
  HOST_ARCH="$(uname -m)"
  # 目的地由模板推导：模板指向可执行文件，要拷的是它所在的目录。
  runtime_dir_for_arch() {
    local arch="$1" path="${JOYHARNESS_RUNTIME_TEMPLATE//\{arch\}/$1}"
    echo "$RESOURCE_DIR/$(dirname "$path")"
  }
  mkdir -p "$(runtime_dir_for_arch "$HOST_ARCH")"
  ditto "$BUNDLED_RUNTIME" "$(runtime_dir_for_arch "$HOST_ARCH")"

  # 另一种架构的 Runtime 由对应机器构建后放进来（见
  # .github/workflows/runtime-x86_64.yml）。指向它的目录即可。
  OTHER_ARCH_RUNTIME="${JOYHARNESS_RUNTIME_BUNDLE_X86_64:-}"
  OTHER_ARCH="x86_64"
  if [ "$HOST_ARCH" = "x86_64" ]; then
    OTHER_ARCH_RUNTIME="${JOYHARNESS_RUNTIME_BUNDLE_ARM64:-}"
    OTHER_ARCH="arm64"
  fi
  if [ -n "$OTHER_ARCH_RUNTIME" ] && [ -x "$OTHER_ARCH_RUNTIME/JoyHarnessRuntime" ]; then
    actual="$(lipo -archs "$OTHER_ARCH_RUNTIME/JoyHarnessRuntime" | tr -d ' ')"
    if [ "$actual" != "$OTHER_ARCH" ]; then
      echo "Runtime at $OTHER_ARCH_RUNTIME is $actual, expected $OTHER_ARCH" >&2
      exit 1
    fi
    mkdir -p "$(runtime_dir_for_arch "$OTHER_ARCH")"
    ditto "$OTHER_ARCH_RUNTIME" "$(runtime_dir_for_arch "$OTHER_ARCH")"
    echo "Bundled runtimes: $HOST_ARCH + $OTHER_ARCH"
  else
    echo "Bundled runtimes: $HOST_ARCH only — the app will not launch on the other architecture." >&2
    echo "Build the missing slice (see .github/workflows/runtime-x86_64.yml) and pass it via" >&2
    echo "JOYHARNESS_RUNTIME_BUNDLE_X86_64 / JOYHARNESS_RUNTIME_BUNDLE_ARM64." >&2
  fi
fi

ICON_WORK_DIR="$ROOT_DIR/build/icon-work"
rm -rf "$ICON_WORK_DIR"
mkdir -p "$ICON_WORK_DIR/JoyHarness.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SELECTED_ICON" --out "$ICON_WORK_DIR/JoyHarness.iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SELECTED_ICON" --out "$ICON_WORK_DIR/JoyHarness.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK_DIR/JoyHarness.iconset" -o "$RESOURCE_DIR/JoyHarness.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>JoyHarness.icns</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <!-- Sparkle decides what is newer by comparing this, not the display
       version. It was a hardcoded 1, which would have meant the updater
       never saw a single release as an upgrade -- the feed would parse, the
       check would run, and nothing would ever be offered. Tracking the
       release version keeps one number to bump. -->
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>JoyHarnessBuildFlavor</key>
  <string>$BUILD_FLAVOR</string>
  <key>JoyHarnessRuntimePath</key>
  <string>$RUNTIME_DIR</string>
  <!-- Sparkle. This address is compiled into every copy we ship and cannot
       be changed for one already installed, which is exactly why it points
       at the feed and not at a package: the enclosure URL inside the feed
       can be repointed at another host whenever it has to move, and every
       install already out there follows along without being rebuilt.
       It left raw.githubusercontent.com because mainland China cannot
       reliably reach it -- self-hosting the download bought the first
       install and nothing after it, so anyone who installed from the site
       stayed on the version they first got. SUPublicEDKey is the public
       half of the update-signing key: an update not signed by the matching
       private key is refused, so a tampered feed or a swapped download
       installs nothing. That signature is what makes it safe to serve both
       of these from a bucket rather than from the release page. -->
  <key>SUFeedURL</key>
  <string>https://joyharness-1305183734.cos.ap-shanghai.myqcloud.com/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>3iMkS5rtHsm6hfNvB/HmjF1nK1D70VFfMJIHi3yzLHc=</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>JoyHarnessRuntimeExecutable</key>
  <string>$JOYHARNESS_RUNTIME_TEMPLATE</string>
  <key>JoyHarnessIPCPath</key>
  <string>$IPC_DIR</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>JoyHarness 需要连接 Joy-Con 以接收按键操作。</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
xattr -cr "$APP_PATH" 2>/dev/null || true

CODESIGN_IDENTITY="${JOYHARNESS_CODESIGN_IDENTITY:-}"
if [ -n "$CODESIGN_IDENTITY" ]; then
  # --timestamp calls out to Apple's timestamp server; on a slow/flaky
  # connection this can hang far longer than a normal build. It's the
  # right default (keeps the signature valid past the cert's own
  # expiration), but JOYHARNESS_CODESIGN_NO_TIMESTAMP=1 skips it for a
  # fast local iteration loop when that round-trip is the bottleneck.
  CODESIGN_FLAGS=(--force --options runtime --sign "$CODESIGN_IDENTITY")
  if [ "${JOYHARNESS_CODESIGN_NO_TIMESTAMP:-0}" != "1" ]; then
    CODESIGN_FLAGS+=(--timestamp)
  fi

  # Sign the bundled runtime from the inside out.
  #
  # Signing the app bundle alone leaves the Python runtime's ~170 dylibs and
  # extension modules ad-hoc signed, because loose Mach-O files under
  # Resources/ are sealed as resources rather than signed as code. macOS is
  # happy with that, so it is invisible locally -- but notarization rejects
  # the submission outright ("not signed with a valid Developer ID
  # certificate"), which is how this was found.
  #
  # Order matters: each signature seals everything beneath it, so anything
  # signed after its container invalidates that container's signature. Deepest
  # path first, app bundle last.
  # Sparkle first, and from the inside out. It carries two XPC services and
  # an updater app, each a bundle in its own right; codesign will not cover
  # them by signing the framework, and an unsigned one fails notarization and
  # is refused at launch.
  SPARKLE_IN_APP="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SPARKLE_IN_APP" ]; then
    # Every Mach-O first, deepest path first, then the bundles that contain
    # them, then the framework version. Listing the bundles by hand missed
    # Versions/B/Autoupdate -- a loose executable, not a bundle -- and
    # notarization rejected the whole submission for it. Sweeping for Mach-O
    # files cannot miss the next one.
    while IFS= read -r macho; do
      [ -n "$macho" ] && codesign "${CODESIGN_FLAGS[@]}" "$macho"
    done < <(
      find "$SPARKLE_IN_APP/Versions/B" -type f -perm +111 -print0 2>/dev/null \
        | xargs -0 file --mime-type 2>/dev/null \
        | awk -F': ' '$2 ~ /application\/x-mach-binary/ {print $1}' \
        | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-
    )
    for nested in \
      "$SPARKLE_IN_APP/Versions/B/XPCServices/Downloader.xpc" \
      "$SPARKLE_IN_APP/Versions/B/XPCServices/Installer.xpc" \
      "$SPARKLE_IN_APP/Versions/B/Updater.app" \
      "$SPARKLE_IN_APP/Versions/B"; do
      [ -e "$nested" ] && codesign "${CODESIGN_FLAGS[@]}" "$nested"
    done
    echo "Signed Sparkle."
  fi

  RUNTIME_ROOT="$RESOURCE_DIR/Runtime"
  if [ -d "$RUNTIME_ROOT" ]; then
    # The runtime is signed with two entitlements the app itself does not get.
    # They live in macos/JoyHarnessRuntime.entitlements, which carries no
    # comments of its own because codesign's parser rejects XML comments.
    #
    #   allow-unsigned-executable-memory, allow-jit
    #
    # PyObjC registers a few hundred struct types while importing, and each
    # needs a libffi closure -- generated code. Hardened Runtime forbids
    # mapping memory writable and executable, so ffi_closure_alloc falls back
    # to writing a temp file and mapping that executable, which is forbidden
    # too, and then retries across every candidate directory, forever.
    #
    # The runtime then starts, logs its config path, and never reaches its
    # first real line of work. That is precisely how it failed on an Intel
    # Mac: sampling the stuck process showed it inside
    # ffi_closure_alloc -> dlmmap -> mkostemp/mmap/close, spinning. Apple
    # Silicon takes a different path in libffi and did not show it, which is
    # why it survived local testing.
    #
    # Hardened Runtime is not optional here -- notarization requires it -- so
    # the runtime gets the entitlement covering what libffi actually does.
    RUNTIME_ENTITLEMENTS="$ROOT_DIR/macos/JoyHarnessRuntime.entitlements"
    [ -f "$RUNTIME_ENTITLEMENTS" ] || {
      echo "Missing $RUNTIME_ENTITLEMENTS" >&2
      exit 1
    }
    RUNTIME_CODESIGN_FLAGS=("${CODESIGN_FLAGS[@]}" --entitlements "$RUNTIME_ENTITLEMENTS")
    echo "Signing the bundled runtime..."
    nested_count=0
    while IFS= read -r macho; do
      codesign "${RUNTIME_CODESIGN_FLAGS[@]}" "$macho"
      nested_count=$((nested_count + 1))
    done < <(
      find "$RUNTIME_ROOT" -type f \
        \( -name '*.dylib' -o -name '*.so' -o -perm +111 \) -print0 \
        | xargs -0 file --mime-type \
        | awk -F': ' '$2 ~ /application\/x-mach-binary/ {print $1}' \
        | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-
    )
    echo "Signed $nested_count nested binaries."

    # Frameworks are signed as bundles, not as the binary inside them --
    # codesign refuses the latter. The versioned directory is the signable
    # unit; signing the .framework root only works when its top-level symlinks
    # are intact, which is not worth depending on.
    while IFS= read -r version_dir; do
      [ -n "$version_dir" ] || continue
      codesign "${RUNTIME_CODESIGN_FLAGS[@]}" "$version_dir"
      echo "Signed framework: ${version_dir#"$RESOURCE_DIR/"}"
    done < <(
      find "$RUNTIME_ROOT" -type d -name '*.framework' \
        -exec find {} -maxdepth 2 -mindepth 2 -type d -path '*/Versions/*' \; 2>/dev/null \
        | grep -v '/Versions/Current$' || true
    )
  fi

  codesign "${CODESIGN_FLAGS[@]}" "$APP_PATH"
else
  codesign \
    --force \
    --sign - \
    --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP_PATH"
fi

codesign --verify --strict --verbose=2 "$APP_PATH"
echo "Built SwiftUI client: $APP_PATH"
echo "Flavor: $BUILD_FLAVOR"
echo "Configuration: $BUILD_CONFIGURATION"
echo "Bundle ID: $BUNDLE_ID"
