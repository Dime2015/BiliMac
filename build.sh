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
# Drop the debug map: it names every object file under this folder (here, inside ~/Downloads). The hang
# recorder runs /usr/bin/sample on the app, sample opens those files to add line numbers, and macOS then asks
# for Downloads access on the app's behalf, again after every rebuild (a new ad-hoc signature). Function names
# stay in the symbol table, so samples are still readable.
strip -S "$APP/Contents/MacOS/BiliMac"
# SwiftPM records the deployment target (14.0) as the SDK the binary was built against, and macOS then
# runs the app in compatibility mode: the old, smaller window buttons and none of the current system
# look. Record the SDK actually used; the minimum system stays 14.0.
# Read it from the SDK swift build used: `xcrun --show-sdk-version` goes through xcodebuild and fails when the
# selected Xcode and an updated Command Line Tools disagree.
SDK=$(/usr/libexec/PlistBuddy -c "Print Version" "$(xcrun --show-sdk-path)/SDKSettings.plist")
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
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
# Which build this is (shown at the bottom of 设置): when it was built and from which commit, "+" when the
# working tree had changes not yet committed.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true)
if [[ -n "$COMMIT" && -n "$(git status --porcelain 2>/dev/null)" ]]; then COMMIT="$COMMIT+"; fi
/usr/libexec/PlistBuddy -c "Add :BiliMacBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
[[ -n "$COMMIT" ]] && /usr/libexec/PlistBuddy -c "Add :BiliMacCommit string $COMMIT" "$APP/Contents/Info.plist"
# macOS remembers privacy grants (the Downloads folder downloads are saved to, for one) by code signature. An
# ad-hoc signature is a new identity on every build, so each rebuild made macOS ask again. Builds for this Mac
# are signed with an Apple Development certificate when the keychain has one (or the identity in
# BILIMAC_SIGN_ID), which keeps the same identity from build to build. The DMG stays ad-hoc: it goes to other
# people, and the certificate names its owner.
SIGN_ID=-
if [[ $DMG == 0 ]]; then
  SIGN_ID=${BILIMAC_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2; exit}')}
  SIGN_ID=${SIGN_ID:--}
fi
codesign --force --timestamp=none --sign "$SIGN_ID" "$APP" >/dev/null
if [[ $SIGN_ID == - ]]; then echo "Signed ad-hoc"; else echo "Signed with $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 | cut -d'(' -f1)"; fi
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
  # Swap the new copy in without quitting a running BiliMac (someone may be watching): copy it next to the old
  # one, then rename. The running app keeps the files it has open and gets the new version when reopened.
  NEW=/Applications/.BiliMac.app.new OLD=/Applications/.BiliMac.app.old
  rm -rf "$NEW" "$OLD"
  ditto "$APP" "$NEW"
  [[ -e /Applications/BiliMac.app ]] && mv /Applications/BiliMac.app "$OLD"
  mv "$NEW" /Applications/BiliMac.app
  rm -rf "$OLD"
  echo "Installed /Applications/BiliMac.app"
  if pgrep -x BiliMac >/dev/null; then echo "BiliMac is running: reopen it to use the new build"; fi
fi

if [[ $RUN == 1 ]]; then
  # Run the binary directly so logs go to this terminal.
  exec "$APP/Contents/MacOS/BiliMac"
fi
