#!/usr/bin/env bash
# Packages libtdjson dylibs (device + simulator) into a dynamic
# TDLibFramework.xcframework that TDLibKit can import.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Tools/build_workdir"
DEV_DYLIB="$(find "$WORK/build-ios" -maxdepth 2 -name 'libtdjson*.dylib' -print -quit)"
SIM_DYLIB="$(find "$WORK/build-sim" -maxdepth 2 -name 'libtdjson*.dylib' -print -quit)"
EXPORT_H="$(find "$WORK" -name tdjson_export.h -print -quit)"
HEADER="$ROOT/Tools/build_workdir/td/td/telegram/td_json_client.h"
STAGE="$WORK/dynamic-framework"
OUT="$ROOT/ThirdParty/TDLibFramework-dynamic.xcframework"

fail() { echo "ERROR: $*" >&2; exit 1; }
[ -n "$DEV_DYLIB" ] && [ -f "$DEV_DYLIB" ] || fail "device dylib not found"
[ -n "$SIM_DYLIB" ] && [ -f "$SIM_DYLIB" ] || fail "simulator dylib not found (build tdjson in build-sim)"
[ -f "$HEADER" ] || fail "td_json_client.h not found"
[ -f "$EXPORT_H" ] || fail "tdjson_export.h not found"

rm -rf "$STAGE" "$OUT"

make_framework() {
  local name="$1"
  local dylib="$2"
  local platform="$3"
  local dir="$STAGE/$name/TDLibFramework.framework"
  mkdir -p "$dir/Headers/td/telegram"
  cp "$dylib" "$dir/TDLibFramework"
  install_name_tool -id "@rpath/TDLibFramework.framework/TDLibFramework" "$dir/TDLibFramework"
  cp "$HEADER" "$dir/Headers/td_json_client.h"
  cp "$EXPORT_H" "$dir/Headers/td/telegram/tdjson_export.h"
  cat > "$dir/Headers/module.modulemap" <<'MAP'
module TDLibFramework {
    header "td_json_client.h"
    export *
}
MAP
  cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>TDLibFramework</string>
  <key>CFBundleIdentifier</key><string>com.fignyagram.TDLibFramework</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>TDLibFramework</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.8.69</string>
  <key>CFBundleVersion</key><string>7601</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST
  echo "==> $name framework ready"
}

make_framework device "$DEV_DYLIB" iPhoneOS
make_framework simulator "$SIM_DYLIB" iPhoneSimulator

xcodebuild -create-xcframework \
  -framework "$STAGE/device/TDLibFramework.framework" \
  -framework "$STAGE/simulator/TDLibFramework.framework" \
  -output "$OUT"

echo "==> Created $OUT"
