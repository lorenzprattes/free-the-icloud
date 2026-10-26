#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build --disable-sandbox -c "$configuration"
binary_dir="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Free the iCloud.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/FreeTheICloud" "$app_dir/Contents/MacOS/FreeTheICloud"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FreeTheICloud</string>
<key>CFBundleIdentifier</key><string>local.free-the-icloud.app</string>
<key>CFBundleName</key><string>Free the iCloud</string>
<key>CFBundleDisplayName</key><string>Free the iCloud</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>Analyze local media and, only after confirmation, create review albums, delete selected items, or replace photos and videos with reviewed smaller copies. No iCloud downloads.</string>
</dict></plist>
PLIST
plutil -extract NSPhotoLibraryUsageDescription raw -o /dev/null "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
