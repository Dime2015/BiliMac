#!/bin/bash
# Builds BiliMac.app (SwiftPM, no Xcode project). Usage: ./build.sh [--run | --install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BiliMac"

APP=build/BiliMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BiliMac"
cp Resources/AppIcon.icns Resources/Logo.png "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.dime2015.BiliMac</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string><string>ja</string></array>
  <key>NSHumanReadableCopyright</key><string>MIT License · Unofficial client, not affiliated with bilibili</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>CFBundleName</key><string>BiliMac</string>
  <key>CFBundleDisplayName</key><string>BiliMac</string>
  <key>CFBundleExecutable</key><string>BiliMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x BiliMac 2>/dev/null || true
  rm -rf /Applications/BiliMac.app
  ditto "$APP" /Applications/BiliMac.app
  echo "Installed /Applications/BiliMac.app"
fi

if [[ "${1:-}" == "--run" ]]; then
  # Run the binary directly so logs go to this terminal.
  exec "$APP/Contents/MacOS/BiliMac"
fi
