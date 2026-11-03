#!/bin/zsh
set -euo pipefail
PROJECT_DIR="/Users/admin/Fignyagram"
ARCHIVE_PATH="/Users/admin/Fignyagram.xcarchive"
PLIST_PATH="$ARCHIVE_PATH/Products/Applications/Fignyagram.app/Contents/Info.plist"
cd "$PROJECT_DIR"
rm -rf "$ARCHIVE_PATH"
xcodebuild -scheme Fignyagram -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "$ARCHIVE_PATH" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 -allowProvisioningUpdates archive
/usr/libexec/PlistBuddy -c "Delete :LSArchitecturePriority" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority array" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority:0 string arm64" "$PLIST_PATH"
plutil -lint "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Print :LSArchitecturePriority" "$PLIST_PATH"
