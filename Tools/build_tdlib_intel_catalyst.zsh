#!/bin/zsh
set -euo pipefail
ROOT=/tmp/td_universal_build
PREFIX=/tmp/openssl-intel-catalyst
SRC=/Users/admin/Fignyagram/Tools/build_workdir
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
rm -rf "$ROOT"
mkdir -p "$ROOT"
curl -sL -o /tmp/openssl-1.1.1w.tar.gz https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz
tar -xzf /tmp/openssl-1.1.1w.tar.gz -C "$ROOT"
mv "$ROOT/openssl-1.1.1w" "$ROOT/openssl-intel-src"
cp -R "$SRC/td" "$ROOT/td"
cp -R "$SRC/ios-cmake" "$ROOT/ios-cmake"
cd "$ROOT/openssl-intel-src"
export CC="$(xcrun -sdk macosx -f clang) -target x86_64-apple-ios15.0-macabi -isysroot $SDKROOT"
export CFLAGS="-DOPENSSL_NO_ASM"
./Configure no-asm darwin64-x86_64-cc no-shared no-tests --prefix="$PREFIX" --openssldir="$PREFIX"
make -j"$(sysctl -n hw.ncpu)"
make install_sw
mkdir -p "$ROOT/build-tdlib-intel-catalyst"
cmake -S "$ROOT/td" -B "$ROOT/build-tdlib-intel-catalyst" -G "Unix Makefiles" -DCMAKE_MAKE_PROGRAM=/usr/bin/make -DCMAKE_TOOLCHAIN_FILE="$ROOT/ios-cmake/ios.toolchain.cmake" -DPLATFORM=MAC_CATALYST -DARCHS=x86_64 -DDEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-DHAVE_GETHOSTUUID=0" -DCMAKE_CXX_FLAGS="-DHAVE_GETHOSTUUID=0" -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a" -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a" -DOPENSSL_INCLUDE_DIR="$PREFIX/include"
cmake --build "$ROOT/build-tdlib-intel-catalyst" --target tdjson -j"$(sysctl -n hw.ncpu)"
INTEL="$ROOT/build-tdlib-intel-catalyst/libtdjson.1.8.69.dylib"
install_name_tool -id "@rpath/TDLibFramework.framework/TDLibFramework" "$INTEL"
ARM=/Users/admin/Fignyagram/ThirdParty/TDLibFramework-dynamic.xcframework/ios-arm64-maccatalyst/TDLibFramework.framework/Versions/A/TDLibFramework
mkdir -p /tmp/universal-gate
lipo -create "$ARM" "$INTEL" -output /tmp/universal-gate/TDLibFramework
cp /tmp/universal-gate/TDLibFramework "$ARM"
lipo -archs "$ARM"
