#!/usr/bin/env bash
# Standalone TDLib build (tdjson static library) for iOS device + simulator.
#
# IMPORTANT: Swiftgram/TDLibFramework is a release wrapper (prebuilt zip built in
# CI). Its `td` submodule builds with plain CMake into libtdjson, NOT into the
# ready-made TDLibFramework.framework. This script therefore produces
# libtdjson-iOS.xcframework (static libs + tdjson.h). Using it as a drop-in
# replacement requires the Swift wrapper target; see docs/TDLIB_REBUILD.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/Tools/build_workdir}"
TDLIB_TAG="${TDLIB_TAG:-v1.8.69}"
TOOLCHAIN="$WORK/ios.toolchain.cmake"
OUT="$ROOT/ThirdParty/tdjson-rebuilt.xcframework"
DEPS="$WORK/tdlib-deps"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"; }

need git
need cmake
need xcodebuild
need python3
mkdir -p "$WORK" "$DEPS"

step "Crypto flags (portable C path, no asm EC)"
export OPENSSL_NO_ASM=1
export CFLAGS="${CFLAGS:-} -DOPENSSL_NO_ASM"
export CXXFLAGS="${CXXFLAGS:-} -DOPENSSL_NO_ASM"

step "Locating local td sources (no network clone)"
TD=""
for candidate in \
  "$WORK/td" \
  "/Users/admin/tdlib-rebuild/TDLibFramework/td" \
  "$ROOT/../tdlib-rebuild/TDLibFramework/td" \
  "$HOME/tdlib-rebuild/TDLibFramework/td" \
  "$WORK/TDLibFramework/td"; do
  if [ -d "$candidate/td/telegram" ]; then TD="$candidate"; break; fi
done
if [ -z "$TD" ]; then
  fail "Local td sources not found (expected ../tdlib-rebuild/TDLibFramework/td)"
fi
echo "==> Using local td sources: $TD"

if [ "$TD" != "$WORK/td" ]; then
  step "Copying td sources to $WORK/td"
  rm -rf "$WORK/td"
  cp -R "$TD" "$WORK/td"
  TD="$WORK/td"
fi

if [ -d "$TD/.git" ]; then
  git -C "$TD" submodule update --init --recursive || true
fi

step "Generating MIME tables (host build)"
HOST_BUILD="$WORK/build-host"
mkdir -p "$HOST_BUILD"
(
  cd "$HOST_BUILD"
  cmake "$TD" -DCMAKE_BUILD_TYPE=Release \
    -DTD_ENABLE_TESTS=OFF -DTD_ENABLE_EXAMPLES=OFF >/dev/null
  cmake --build . --target tdmime_auto -j "$(sysctl -n hw.ncpu)" >/dev/null
  # Generates td_api_*.cpp, e2e_api.* and other files required for cross builds.
  cmake --build . --target prepare_cross_compiling -j "$(sysctl -n hw.ncpu)" >/dev/null
)
echo "==> Generated: $(ls "$TD/tdutils/generate/auto" | wc -l | tr -d ' ') files"

step "Preparing iOS CMake toolchain"
if [ ! -f "$TOOLCHAIN" ]; then
  git clone --depth 1 https://github.com/leetal/ios-cmake.git "$WORK/ios-cmake"
  cp "$WORK/ios-cmake/ios.toolchain.cmake" "$TOOLCHAIN"
fi

step "Preparing OpenSSL (from Homebrew, must be an iOS build; see docs)"
OPENSSL_ROOT="${OPENSSL_ROOT_DIR:-}"
if [ -z "$OPENSSL_ROOT" ]; then
  if command -v brew >/dev/null 2>&1 && brew --prefix openssl@3 >/dev/null 2>&1; then
    OPENSSL_ROOT="$(brew --prefix openssl@3)"
  fi
fi
if [ -z "$OPENSSL_ROOT" ] || [ ! -d "$OPENSSL_ROOT" ]; then
  fail "OpenSSL for iOS not found. Set OPENSSL_ROOT_DIR to an iOS OpenSSL build (see docs/TDLIB_REBUILD.md)."
fi
echo "==> OpenSSL: $OPENSSL_ROOT"

build_platform() {
  local platform="$1" builddir="$2"
  step "Configuring $platform"
  mkdir -p "$builddir"
  (
    cd "$builddir"
    cmake "$TD" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
      -DPLATFORM="$platform" \
      -DDEPLOYMENT_TARGET=15.0 \
      -DENABLE_BITCODE=OFF \
      -DTD_ENABLE_DOTNET=OFF \
      -DTD_ENABLE_JNI=OFF \
      -DTD_ENABLE_TESTS=OFF \
      -DTD_ENABLE_EXAMPLES=OFF \
      -DTD_ENABLE_OPENSSL=ON \
      -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT" \
      -DOPENSSL_USE_STATIC_LIBS=TRUE \
      -DTD_ENABLE_LTO=OFF
    step "Building $platform"
    cmake --build . --target tdjson_static --config Release -j "$(sysctl -n hw.ncpu)"
  ) 2>&1 | tee "$WORK/build-$platform.log"
}

mkdir -p "$WORK/build-ios" "$WORK/build-sim"
build_platform OS64 "$WORK/build-ios"
build_platform SIMULATORARM64 "$WORK/build-sim"

step "Packaging xcframework"
DEVICE_LIB="$(find "$WORK/build-ios" -name 'libtdjson_static.a' -print -quit)"
SIM_LIB="$(find "$WORK/build-sim" -name 'libtdjson_static.a' -print -quit)"
[ -n "$DEVICE_LIB" ] || fail "device libtdjson.a not found"
[ -n "$SIM_LIB" ] || fail "simulator libtdjson.a not found"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$TD/td/telegram" \
  -library "$SIM_LIB" -headers "$TD/td/telegram" \
  -output "$OUT"

step "Done: $OUT"
cat <<EOF
Built static tdjson for device + simulator with OPENSSL_NO_ASM.

NOTE: this is NOT a drop-in TDLibFramework.framework. Swiftgram's wrapper is
produced by their CI. To use this build you must either:
  * build/link the Swift wrapper yourself against these static libs, or
  * consume tdjson via a C shim + SPM target.
See docs/TDLIB_REBUILD.md for both paths and rollback steps.
EOF
