#!/bin/zsh
# Sestaví "build/Tesla Preview.app" (Apple Silicon, ad-hoc podpis).
set -euo pipefail
unset GOROOT

cd "${0:A:h}/.."
swift build -c release --arch arm64

APP="build/Tesla Preview.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/TeslaPreview" "$APP/Contents/MacOS/TeslaPreview"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tesla Preview</string>
    <key>CFBundleDisplayName</key><string>Tesla Preview</string>
    <key>CFBundleIdentifier</key><string>local.teslapreview</string>
    <key>CFBundleExecutable</key><string>TeslaPreview</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>cs</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Hotovo: $PWD/$APP"
