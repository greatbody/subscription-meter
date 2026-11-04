#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
app="$PWD/build/Subscription Meter.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
icon_dir=$(mktemp -d "${TMPDIR:-/tmp}/subscription-meter-icon.XXXXXX")
trap 'rm -r "$icon_dir"' EXIT
mkdir "$icon_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" design/app-icon-concept.png --out "$icon_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" design/app-icon-concept.png --out "$icon_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
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
<key>CFBundleIconFile</key><string>AppIcon</string>
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
