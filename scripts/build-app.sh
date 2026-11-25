#!/bin/sh
# Builds a signed build/MouseBridge.app.
# Usage: scripts/build-app.sh [version]   (default 0.0.0; build number = commit count)
# Signs with the "Developer ID Application" identity, or SIGN_ID if set.
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
APP=build/MouseBridge.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN/MouseBridge" "$APP/Contents/MacOS/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>it.realdoc06.mousebridge</string>
  <key>CFBundleName</key><string>MouseBridge</string>
  <key>CFBundleExecutable</key><string>MouseBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>https://github.com/RealDoc06/mousebridge/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>aHsE+AwlsD0JXOKBehtZHizVb+sjWmuWIuQrUCR25XM=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST

# Sparkle's nested helpers are signed inside out, then the app (Sparkle's documented order).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$@"; }
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP $VERSION ($BUILD)"
