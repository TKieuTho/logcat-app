#!/bin/bash
# Builds Sun Firebase Event Studio.app, ad-hoc signs it, installs to ~/Applications.
set -e
VERSION="$(cat "$(dirname "$0")/VERSION" 2>/dev/null || echo 0.0.0)"
cd "$(dirname "$0")"
APP_NAME="Logcat"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install
  echo "Install Xcode Command Line Tools, then run this script again."; read -n1 -p "Press any key"; exit 1
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)/SunFirebaseEventStudio"
APP="build/$APP_NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SunFirebaseEventStudio"
cp Resources/AppIcon.icns Resources/cat.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>studio.sun.firebase-event-studio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>SunFirebaseEventStudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep --sign - "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Sun Firebase Event Studio.app" "$HOME/Applications/$APP_NAME.app"
cp -R "$APP" "$HOME/Applications/"
xattr -dr com.apple.quarantine "$HOME/Applications/$APP_NAME.app" 2>/dev/null || true
echo "Installed: $HOME/Applications/$APP_NAME.app"
open "$HOME/Applications"
