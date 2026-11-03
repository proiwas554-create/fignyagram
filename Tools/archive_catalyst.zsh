#!/bin/zsh
set -euo pipefail
PROJECT_DIR="/Users/admin/Fignyagram"
ARCHIVE_PATH="/Users/admin/Fignyagram-universal.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/Fignyagram.app"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
FW_PATH="$APP_PATH/Contents/Frameworks/TDLibFramework.framework"
cd "$PROJECT_DIR"
rm -rf "$ARCHIVE_PATH"
xcodebuild -scheme Fignyagram -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "$ARCHIVE_PATH" -allowProvisioningUpdates archive
rm -f "$FW_PATH/TDLibFramework"
ln -s Versions/Current/TDLibFramework "$FW_PATH/TDLibFramework"
/usr/libexec/PlistBuddy -c "Delete :LSArchitecturePriority" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority array" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority:0 string arm64" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority:1 string x86_64" "$PLIST_PATH"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
plutil -lint "$PLIST_PATH"
lipo -archs "$APP_PATH/Contents/MacOS/Fignyagram"
/usr/libexec/PlistBuddy -c "Print :LSArchitecturePriority" "$PLIST_PATH"
