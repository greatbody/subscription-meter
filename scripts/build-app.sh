#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
app="$PWD/build/Subscription Meter.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R Resources/ProviderIcons "$app/Contents/Resources/"
cp .build/apple/Products/Release/SubscriptionMeter "$app/Contents/MacOS/SubscriptionMeter"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SubscriptionMeter</string>
<key>CFBundleIdentifier</key><string>ink.sunrui.subscription-meter</string>
<key>CFBundleName</key><string>Subscription Meter</string>
<key>CFBundleDisplayName</key><string>Subscription Meter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
