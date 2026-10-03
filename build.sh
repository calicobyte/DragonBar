#!/bin/zsh
# Builds DragonBar.app next to this script.
set -e
cd "$(dirname "$0")"

APP=DragonBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/DragonBar" -framework Cocoa

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DragonBar</string>
    <key>CFBundleIdentifier</key><string>com.claude.dragonbar</string>
    <key>CFBundleExecutable</key><string>DragonBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $(pwd)/$APP"
