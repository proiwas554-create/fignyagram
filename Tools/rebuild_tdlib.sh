#!/usr/bin/env bash
# Rebuilds Swiftgram/TDLibFramework from source so the BoringSSL/OpenSSL used by
# TDLib no longer crashes in BN_nnmod while parsing EC server certificates.
#
# Requirements: Xcode 26+, cmake, ninja (or make), git, ~20 GB free disk.
# Usage:
#   TAG=1.8.69-18d36ada ./Tools/rebuild_tdlib.sh [work-dir]
#   BUILD_ARGS="--disable_asm" ./Tools/rebuild_tdlib.sh
set -euo pipefail

REPO_URL="https://github.com/Swiftgram/TDLibFramework"
TAG="${TAG:-1.8.69-18d36ada}"
WORK="${1:-$(pwd)/../tdlib-rebuild}"
OUT="$(pwd)/ThirdParty/TDLibFramework-rebuilt.xcframework"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"; }

need git
need xcodebuild
need cmake
need python3

step "Workspace: $WORK"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -d TDLibFramework/.git ]; then
  step "Cloning $REPO_URL"
  git clone --recursive "$REPO_URL" TDLibFramework
fi
cd TDLibFramework
git fetch --tags --force
git checkout "$TAG"
git submodule update --init --recursive

step "Applying OpenSSL stability flags"
# The crash is inside OpenSSL's EC group setup. Disabling assembly keeps the
# portable C implementation, which avoids the faulty asm path on arm64 while we
# stay on the same TDLib version.
export CFLAGS="${CFLAGS:-} -DOPENSSL_NO_ASM"
export CXXFLAGS="${CXXFLAGS:-} -DOPENSSL_NO_ASM"
export OPENSSL_NO_ASM=1

if [ -f build.sh ]; then
  step "Running upstream build.sh (log: $WORK/build.log)"
  # shellcheck disable=SC2086
  ./build.sh ${BUILD_ARGS:-} 2>&1 | tee "$WORK/build.log"
else
  fail "build.sh not found in $TAG — inspect the tag layout and adjust this script"
fi

step "Locating built xcframework"
FOUND="$(find "$WORK" -maxdepth 5 -name 'TDLibFramework.xcframework' -print -quit || true)"
[ -n "$FOUND" ] || fail "TDLibFramework.xcframework not found; check $WORK/build.log"
step "Found: $FOUND"

step "Copying to project: $OUT"
rm -rf "$OUT"
cp -R "$FOUND" "$OUT"

step "Verifying slices"
/usr/bin/lipo -info "$OUT/ios-arm64/TDLibFramework.framework/TDLibFramework" 2>/dev/null || true
plutil -p "$OUT/Info.plist" | head -30 || true

cat <<EOF

DONE. Next steps (see docs/TDLIB_REBUILD.md):
  1. Replace the framework used by the local TDLibKit package:
       cp -R "$OUT" "$HOME/Downloads/TDLibKit-1.5.2-tdlib-1.8.68-7601cdfb/TDLibFramework.xcframework"
  2. Update its Package.swift binaryTarget path if needed.
  3. In the app: xcodebuild -resolvePackageDependencies && build.
EOF
