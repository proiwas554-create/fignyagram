#!/usr/bin/env bash
# Packages libtdjson_static.a (+ static OpenSSL) into a module-capable
# TDLibFramework.xcframework that TDLibKit can import.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ThirdParty/tdjson-rebuilt.xcframework"
DEV_SSL="${DEV_OPENSSL:-/tmp/openssl-ios}"
SIM_SSL="${SIM_OPENSSL:-/tmp/openssl-ios-sim}"
HEADER_SRC="$ROOT/Tools/build_workdir/td/td/telegram/td_json_client.h"
OUT="$ROOT/ThirdParty/TDLibFramework-rebuilt.xcframework"
STAGE="$ROOT/Tools/build_workdir/package"

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ -f "$SRC/ios-arm64/libtdjson_static.a" ] || fail "device slice missing in $SRC"
[ -f "$SRC/ios-arm64-simulator/libtdjson_static.a" ] || fail "simulator slice missing in $SRC"
[ -f "$DEV_SSL/lib/libssl.a" ] || fail "device OpenSSL not found in $DEV_SSL"
[ -f "$SIM_SSL/lib/libssl.a" ] || fail "simulator OpenSSL not found in $SIM_SSL (build it with openssl Configure for the simulator)"
[ -f "$HEADER_SRC" ] || fail "td_json_client.h not found at $HEADER_SRC"

platform_of() {
  local archive="$1" tmp
  tmp="$(mktemp -d)"
  ( cd "$tmp" && ar -x "$archive" >/dev/null 2>&1 )
  local obj
  obj="$(ls "$tmp"/*.o 2>/dev/null | head -1)"
  [ -n "$obj" ] || { rm -rf "$tmp"; echo unknown; return; }
  vtool -show-build "$obj" 2>/dev/null | awk '/platform/ {print $2; exit}'
  rm -rf "$tmp"
}

step "Checking OpenSSL platforms"
DEV_PLATFORM="$(platform_of "$DEV_SSL/lib/libcrypto.a")"
SIM_PLATFORM="$(platform_of "$SIM_SSL/lib/libcrypto.a")"
echo "device openssl: $DEV_PLATFORM"
echo "simulator openssl: $SIM_PLATFORM"
[ "$DEV_PLATFORM" = "IOS" ] || fail "device OpenSSL is not IOS ($DEV_PLATFORM)"
[ "$SIM_PLATFORM" = "IOSSIMULATOR" ] || fail "simulator OpenSSL is not IOSSIMULATOR ($SIM_PLATFORM)"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/device" "$STAGE/simulator"

package_slice() {
  local name="$1" lib="$2" ssl="$3" dir="$STAGE/$name"
  mkdir -p "$dir/Headers"
  step "Merging $name"
  libtool -static -o "$dir/libTDLibFramework.a" \
    "$lib" "$ssl/libssl.a" "$ssl/libcrypto.a"
  cp "$HEADER_SRC" "$dir/Headers/"
  cp "$ROOT/Tools/build_workdir/td/td/telegram/td_json_client.h" "$dir/Headers/" 2>/dev/null || true
  cat > "$dir/Headers/module.modulemap" <<'MAP'
module TDLibFramework {
    header "td_json_client.h"
    export *
}
MAP
  lipo -info "$dir/libTDLibFramework.a"
}

package_slice device "$SRC/ios-arm64/libtdjson_static.a" "$DEV_SSL"
package_slice simulator "$SRC/ios-arm64-simulator/libtdjson_static.a" "$SIM_SSL"

step "Creating xcframework"
xcodebuild -create-xcframework \
  -library "$STAGE/device/libTDLibFramework.a" -headers "$STAGE/device/Headers" \
  -library "$STAGE/simulator/libTDLibFramework.a" -headers "$STAGE/simulator/Headers" \
  -output "$OUT"

step "Done: $OUT"
cat <<EOF
Next:
  1. Point the local TDLibKit binaryTarget at this xcframework.
  2. Re-resolve packages and build.
  3. Only then remove the NetworkIgnition gate.
EOF
