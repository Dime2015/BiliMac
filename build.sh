#!/bin/bash
# Builds BiliMac.app (SwiftPM, no Xcode project).
# Usage: ./build.sh [--install] [--run] [--universal] [--dmg]
#   --install    copy the app to /Applications
#   --run        run the built binary (logs go to this terminal)
#   --universal  Apple Silicon + Intel binary
#   --dmg        universal build packed into build/BiliMac-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0 RUN=0 UNIVERSAL=0 DMG=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1; UNIVERSAL=1 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

ARCHS=()
if [[ $UNIVERSAL == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/BiliMac"

APP=build/BiliMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BiliMac"
# SwiftPM records the deployment target (14.0) as the SDK the binary was built against, and macOS then
# runs the app in compatibility mode: the old, smaller window buttons and none of the current system
# look. Record the SDK actually used; the minimum system stays 14.0.
SDK=$(xcrun --show-sdk-version)
vtool -set-build-version macos 14.0 "$SDK" -replace -output "$APP/Contents/MacOS/BiliMac" "$APP/Contents/MacOS/BiliMac" 2>/dev/null
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
  <key>CFBundleShortVersionString</key><string>1.2.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

if [[ $DMG == 1 ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  STAGE=build/dmg
  OUT="build/BiliMac-$VERSION.dmg"
  rm -rf "$STAGE" "$OUT"
  mkdir -p "$STAGE"
  # No extended attributes or resource forks from this machine in the image.
  ditto --norsrc --noextattr "$APP" "$STAGE/BiliMac.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "BiliMac" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
  rm -rf "$STAGE"
  echo "Packed $(pwd)/$OUT"
fi

if [[ $INSTALL == 1 ]]; then
  pkill -x BiliMac 2>/dev/null || true
  rm -rf /Applications/BiliMac.app
  ditto "$APP" /Applications/BiliMac.app
  echo "Installed /Applications/BiliMac.app"
fi

if [[ $RUN == 1 ]]; then
  # Run the binary directly so logs go to this terminal.
  exec "$APP/Contents/MacOS/BiliMac"
fi
