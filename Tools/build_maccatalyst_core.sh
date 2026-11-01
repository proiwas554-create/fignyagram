#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Tools/build_workdir"
SRC_TGZ=/tmp/openssl-1.1.1w.tar.gz
SRC=/tmp/openssl-1.1.1w-catalyst
PREFIX=/tmp/openssl-maccatalyst
BUILD="$WORK/build-catalyst"
OUT="$ROOT/ThirdParty/TDLibFramework-dynamic.xcframework"
log(){ printf '\n==> %s\n' "$*"; }

if [ ! -d "$PREFIX/lib" ]; then
  log "OpenSSL 1.1.1w for Mac Catalyst (no-asm)"
  rm -rf "$SRC"; mkdir -p "$SRC"; tar -xzf "$SRC_TGZ" -C "$SRC" --strip-components=1
  cd "$SRC"
  export CC="$(xcrun -sdk macosx -f clang) -target arm64-apple-ios15.0-macabi -isysroot $(xcrun --sdk macosx --show-sdk-path)"
  export CFLAGS="-DOPENSSL_NO_ASM"
  ./Configure darwin64-arm64-cc no-asm no-shared no-tests --prefix="$PREFIX" --openssldir="$PREFIX"
  make -j8
  make install_sw
fi

log "TDLib tdjson for Mac Catalyst"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cmake -S "$WORK/td" -B "$BUILD" -G "Unix Makefiles" -DCMAKE_MAKE_PROGRAM=/usr/bin/make \
  -DCMAKE_TOOLCHAIN_FILE="$WORK/ios-cmake/ios.toolchain.cmake" \
  -DPLATFORM=MAC_CATALYST_ARM64 -DARCHS=arm64 -DDEPLOYMENT_TARGET=${CATALYST_MIN:-15.0} \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-DHAVE_GETHOSTUUID=0" \
  -DCMAKE_CXX_FLAGS="-DHAVE_GETHOSTUUID=0" \
  -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a" \
  -DOPENSSL_INCLUDE_DIR="$PREFIX/include" \
  -DTD_ENABLE_EXPORTED_SYMBOLS=ON
cmake --build "$BUILD" --target tdjson -j8

DYLIB="$(find "$BUILD" -maxdepth 2 -name 'libtdjson*.dylib' -print -quit)"
[ -f "$DYLIB" ] || { echo "no catalyst dylib"; exit 1; }
lipo -info "$DYLIB"

log "Packaging three-slice xcframework"
STAGE="$WORK/catalyst-framework/TDLibFramework.framework"
rm -rf "$WORK/catalyst-framework"; mkdir -p "$STAGE/Headers/td/telegram" "$STAGE/Modules"
cp "$DYLIB" "$STAGE/TDLibFramework"
install_name_tool -id "@rpath/TDLibFramework.framework/TDLibFramework" "$STAGE/TDLibFramework"
EXPORT_H="$(find "$WORK" -name tdjson_export.h -print -quit)"
cp "$WORK/td/td/telegram/td_json_client.h" "$STAGE/Headers/"
cp "$EXPORT_H" "$STAGE/Headers/tdjson_export.h"
cp "$WORK/td/td/telegram/td_log.h" "$STAGE/Headers/"
sed -i '' 's|#include "td/telegram/tdjson_export.h"|#include "tdjson_export.h"|' "$STAGE/Headers/"*.h
printf '#import "td_json_client.h"\n#import "td_log.h"\n' > "$STAGE/Headers/td.h"
cat > "$STAGE/Modules/module.modulemap" <<'MAP'
framework module TDLibFramework {
  umbrella header "td.h"
  export *
  module * { export * }
}
MAP
cat > "$STAGE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TDLibFramework</string>
<key>CFBundleIdentifier</key><string>com.fignyagram.TDLibFramework</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.8.69</string>
<key>CFBundleVersion</key><string>7601</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>MinimumOSVersion</key><string>12.0</string>
<key>AppExtensionSafe</key><true/>
</dict></plist>
PLIST

xcodebuild -create-xcframework \
  -framework "$OUT/ios-arm64/TDLibFramework.framework" \
  -framework "$OUT/ios-arm64-simulator/TDLibFramework.framework" \
  -framework "$STAGE" \
  -output "$OUT.new"
rm -rf "$OUT"; mv "$OUT.new" "$OUT"
echo "Done: $OUT"
